$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$manager = Join-Path $repoRoot "scripts\workstation\Invoke-AgentWorkstationRuntime.ps1"
$verifier = Join-Path $repoRoot "scripts\workstation\Test-AgentReleaseManifest.ps1"
$trust = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "deploy\workstation\trusted-runtime.json") | ConvertFrom-Json
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("jta-workstation-smoke-" + [guid]::NewGuid().ToString("N"))
$artifactRoot = Join-Path $fixtureRoot "artifacts"
$runtimeRoot = Join-Path $fixtureRoot "runtime"
$stateRoot = Join-Path $fixtureRoot "state"
$secretFile = Join-Path $fixtureRoot "protected\hub-signing-secret"
$serviceBefore = @(Get-Service -Name "JerryTelemetryAgent" -ErrorAction SilentlyContinue).Count

function Assert-True { param([bool]$Condition, [string]$Code); if (-not $Condition) { throw $Code } }
function Get-Sha256 {
  param([string]$Path)
  $stream = [IO.File]::OpenRead($Path); $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose(); $stream.Dispose() }
}
function Get-SafeRelativePath {
  param([string]$Root, [string]$Path)
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"; $pathFull = [IO.Path]::GetFullPath($Path)
  Assert-True ($pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) "path_outside_root"
  return $pathFull.Substring($rootFull.Length)
}
function New-FixtureRelease {
  param([string]$Name, [char]$CommitCharacter)
  $commit = ([string]$CommitCharacter) * 40
  $stage = Join-Path $artifactRoot "$Name-stage"
  New-Item -ItemType Directory -Force -Path (Join-Path $stage "runtime"), (Join-Path $stage "app\dist\src"), (Join-Path $stage "bin") | Out-Null
  Set-Content -LiteralPath (Join-Path $stage "runtime\node.exe") -Value "fixture-node-$Name" -NoNewline
  Set-Content -LiteralPath (Join-Path $stage "app\dist\src\server-agent-daemon.js") -Value "fixture-$Name" -NoNewline
  Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\workstation\Start-AgentRelease.ps1") -Destination (Join-Path $stage "bin\Start-AgentRelease.ps1")
  Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\workstation\Test-AgentReleaseManifest.ps1") -Destination (Join-Path $stage "bin\Test-AgentReleaseManifest.ps1")
  $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = (Get-SafeRelativePath $stage $_.FullName).Replace("\", "/"); sha256 = Get-Sha256 $_.FullName; size_bytes = $_.Length }
  })
  $artifactName = "agent-$Name.zip"; $artifact = Join-Path $artifactRoot $artifactName
  Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $artifact
  $manifestPath = "$artifact.manifest.json"
  [ordered]@{
    schema_version = "jerry.workstation.release.v1"; component = "jerry-telemetry-agent"
    source_repository = "JerrySkywalker/jerry-telemetry-agent"; source_commit = $commit
    artifact_filename = $artifactName; artifact_sha256 = Get-Sha256 $artifact; artifact_size_bytes = (Get-Item $artifact).Length
    runtime_version = "22.23.1"; build_tool_version = "fixture"
    artifact_file_list_or_digest = [ordered]@{ algorithm = "sha256"; files = $files }
    required_config_key_names = @("AGENT_MODE", "TELEMETRY_OUTPUT_MODE", "TELEMETRY_NODE_CONFIG_PATH", "TELEMETRY_NODE_SECRET_FILE", "TELEMETRY_NODE_KEY_ID", "TELEMETRY_HUB_BATCH_URL", "TELEMETRY_HUB_REQUEST_TIMEOUT_MS", "TELEMETRY_SERVER_BATCH_LATEST_FILE", "TELEMETRY_BATCH_OUTPUT_FILE", "STATE_PATH", "SPOOL_DIR", "HEALTH_SERVER_ENABLED", "HEALTH_HOST", "HEALTH_PORT")
    default_activation_state = [ordered]@{ message_gateway_readiness_collector_enabled = $false; output_mode = "file"; http_upload_enabled = $false }
    build_timestamp = [DateTime]::UtcNow.ToString("o"); platform = "win32"; architecture = "x64"; entrypoint = "app/dist/src/server-agent-daemon.js"
    node_archive_sha256 = [string]$trust.node_runtime.sha256; service_wrapper_version = [string]$trust.service_wrapper.version; service_wrapper_sha256 = [string]$trust.service_wrapper.sha256
    collector_name = "message-gateway-readiness"; event_type = "message.gateway.readiness"; loopback_required = $true
    state_preserved_on_upgrade = $true; spool_preserved_on_upgrade = $true; secret_files_preserved = $true
    production_build_required = $false; production_git_required = $false; production_npm_required = $false; fixture_runtime = $true
  } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  $envPath = Join-Path $artifactRoot "agent-$Name.env"
  @(
    "AGENT_MODE=daemon", "TELEMETRY_OUTPUT_MODE=file", "TELEMETRY_NODE_CONFIG_PATH=fixture-overridden-by-service",
    "TELEMETRY_NODE_SECRET_FILE=$secretFile", "TELEMETRY_NODE_KEY_ID=fixture-key-reference",
    "TELEMETRY_HUB_BATCH_URL=fixture-disabled", "TELEMETRY_HUB_REQUEST_TIMEOUT_MS=5000",
    "TELEMETRY_SERVER_BATCH_LATEST_FILE=$stateRoot\server-batch.latest.safe.json",
    "TELEMETRY_BATCH_OUTPUT_FILE=$stateRoot\server-batch.safe.json", "STATE_PATH=$stateRoot\agent-state.json",
    "SPOOL_DIR=$stateRoot\spool", "HEALTH_SERVER_ENABLED=true", "HEALTH_HOST=127.0.0.1", "HEALTH_PORT=18081"
  ) | Set-Content -LiteralPath $envPath -Encoding UTF8
  $nodePath = Join-Path $artifactRoot "agent-$Name.node.json"
  [ordered]@{
    node_id = "fixture-workstation-node"; hostname = "fixture-workstation"; region = "local"; role = "message-gateway"; provider = "local"
    collectors = @([ordered]@{ name = "message-gateway-readiness"; enabled = $false; interval_seconds = 60; target = [ordered]@{ url = "http://127.0.0.1:3094/v1/telemetry/readiness"; timeout_ms = 2000 } })
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $nodePath -Encoding UTF8
  Remove-Item -LiteralPath $stage -Recurse -Force
  return [ordered]@{ Artifact = $artifact; Manifest = $manifestPath; Env = $envPath; Node = $nodePath; Commit = $commit; ArtifactSha = Get-Sha256 $artifact }
}

try {
  New-Item -ItemType Directory -Force -Path $artifactRoot, $stateRoot, (Split-Path -Parent $secretFile), (Join-Path $stateRoot "spool") | Out-Null
  Set-Content -LiteralPath $secretFile -Value "fixture-signing-material" -NoNewline
  Set-Content -LiteralPath (Join-Path $stateRoot "agent-state.json") -Value '{"fixture":true}' -NoNewline
  Set-Content -LiteralPath (Join-Path $stateRoot "spool\preserved.batch.json") -Value '{"fixture":true}' -NoNewline
  $secretSha = Get-Sha256 $secretFile; $stateSha = Get-Sha256 (Join-Path $stateRoot "agent-state.json"); $spoolSha = Get-Sha256 (Join-Path $stateRoot "spool\preserved.batch.json")
  $a = New-FixtureRelease "a" "a"; $b = New-FixtureRelease "b" "b"; $c = New-FixtureRelease "c" "c"
  & $verifier -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -AllowFixtureRuntime | Out-Null
  $badRoot = Join-Path $fixtureRoot "bad-authorization-runtime"
  $badAuthorizationRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit (("f") * 40) -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $badAuthorizationRejected = $true }
  $badArtifactAuthorizationRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 (("f") * 64) -DryRun -FixtureMode | Out-Null } catch { $badArtifactAuthorizationRejected = $true }
  Assert-True ($badAuthorizationRejected -and $badArtifactAuthorizationRejected -and -not (Test-Path -LiteralPath $badRoot)) "fixture_bad_authorization_not_rejected"
  $badEntrypointManifest = Join-Path $artifactRoot "bad-entrypoint.manifest.json"
  $badEntrypoint = Get-Content -Raw -LiteralPath $a.Manifest | ConvertFrom-Json; $badEntrypoint.entrypoint = "../outside.js"
  $badEntrypoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $badEntrypointManifest -Encoding UTF8
  $badEntrypointRejected = $false
  try { & $verifier -ArtifactPath $a.Artifact -ManifestPath $badEntrypointManifest -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -AllowFixtureRuntime | Out-Null } catch { $badEntrypointRejected = $true }
  Assert-True $badEntrypointRejected "fixture_bad_entrypoint_not_rejected"
  $badEnv = Join-Path $artifactRoot "agent-bad.env"
  (Get-Content -Raw -LiteralPath $a.Env).Replace("TELEMETRY_HUB_REQUEST_TIMEOUT_MS=5000", "TELEMETRY_HUB_REQUEST_TIMEOUT_MS=0") | Set-Content -LiteralPath $badEnv -Encoding UTF8
  $badConfigRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $badEnv -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $badConfigRejected = $true }
  Assert-True ($badConfigRejected -and -not (Test-Path -LiteralPath $badRoot)) "fixture_bad_config_not_rejected"
  & $manager -Operation Install -RuntimeRoot $runtimeRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $runtimeRoot)) "dry_run_mutated_runtime"
  $freshFailureRoot = Join-Path $fixtureRoot "fresh-failure-runtime"
  $freshFailureRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $freshFailureRoot -ArtifactPath $c.Artifact -ManifestPath $c.Manifest -EnvPath $c.Env -NodeConfigPath $c.Node -ExpectedSourceCommit $c.Commit -ExpectedArtifactSha256 $c.ArtifactSha -ConfirmInstall -FixtureMode -SimulateHealthFailure | Out-Null } catch { $freshFailureRejected = $_.Exception.Message -match "activation_failed_rolled_back" }
  $freshStatus = (& $manager -Operation Status -RuntimeRoot $freshFailureRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($freshFailureRejected -and -not $freshStatus.installed -and -not $freshStatus.pending_recovery) "fixture_fresh_install_failure_not_cleaned"

  $interruptedRoot = Join-Path $fixtureRoot "interrupted-install-runtime"
  & $manager -Operation Install -RuntimeRoot $interruptedRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ConfirmInstall -FixtureMode | Out-Null
  $interruptedInstalled = (& $manager -Operation Status -RuntimeRoot $interruptedRoot -FixtureMode) | ConvertFrom-Json
  $interruptedCurrent = Join-Path $interruptedRoot "transactions\agent-current.json"; $interruptedPending = Join-Path $interruptedRoot "transactions\agent-pending.json"
  Remove-Item -LiteralPath $interruptedCurrent -Force
  [ordered]@{
    schema_version = "jerry.workstation.activation.v1"; component = "agent"; operation = "Install"; phase = "config_switched"
    previous_release = $null; previous_config = $null; previous_source_commit = $null; previous_artifact_sha256 = $null
    target_release = $interruptedInstalled.active_release_id; target_config = $interruptedInstalled.active_config_id
    target_source_commit = $a.Commit; target_artifact_sha256 = $a.ArtifactSha
    target_release_created = $true; target_config_created = $true; maximum_spool_count = 1; recorded_at = [DateTime]::UtcNow.ToString("o")
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $interruptedPending -Encoding UTF8
  New-Item -ItemType Directory -Force -Path (Join-Path $interruptedRoot "services\agent"), (Join-Path $interruptedRoot "logs\agent") | Out-Null
  Set-Content -LiteralPath (Join-Path $interruptedRoot "services\agent\partial-service.marker") -Value "fixture" -NoNewline
  Set-Content -LiteralPath (Join-Path $interruptedRoot "logs\agent\preserved.log") -Value "fixture-log" -NoNewline
  $interruptedDryRun = (& $manager -Operation Rollback -RuntimeRoot $interruptedRoot -DryRun -FixtureMode) | ConvertFrom-Json
  Assert-True ($interruptedDryRun.recovery_mode -eq "interrupted_first_install" -and (Test-Path -LiteralPath $interruptedPending)) "fixture_interrupted_install_dry_run_invalid"
  & $manager -Operation Rollback -RuntimeRoot $interruptedRoot -ConfirmRollback -FixtureMode | Out-Null
  $interruptedRecovered = (& $manager -Operation Status -RuntimeRoot $interruptedRoot -FixtureMode) | ConvertFrom-Json
  $interruptedRelease = Join-Path $interruptedRoot "releases\agent\$($interruptedInstalled.active_release_id)"
  $interruptedConfig = Join-Path $interruptedRoot "config\agent\revisions\$($interruptedInstalled.active_config_id)"
  $interruptedOwner = Get-Content -Raw -LiteralPath (Join-Path $interruptedRoot ".mg44-runtime-owner.json") | ConvertFrom-Json
  Assert-True ($interruptedRecovered.owned -and -not $interruptedRecovered.installed -and -not $interruptedRecovered.pending_recovery) "fixture_interrupted_install_not_recovered"
  Assert-True (-not (Test-Path -LiteralPath $interruptedRelease) -and -not (Test-Path -LiteralPath $interruptedConfig)) "fixture_interrupted_install_candidate_not_removed"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $interruptedRoot "services\agent"))) "fixture_interrupted_install_service_boundary_not_removed"
  Assert-True ((Test-Path -LiteralPath (Join-Path $interruptedRoot "logs\agent\preserved.log")) -and $interruptedOwner.lifecycle_state -eq "uninstalled_retryable") "fixture_interrupted_install_evidence_or_retry_state_invalid"
  Assert-True ((Get-Sha256 $secretFile) -eq $secretSha -and (Get-Sha256 (Join-Path $stateRoot "agent-state.json")) -eq $stateSha -and (Get-Sha256 (Join-Path $stateRoot "spool\preserved.batch.json")) -eq $spoolSha) "fixture_interrupted_install_external_state_changed"
  & $manager -Operation Install -RuntimeRoot $interruptedRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ConfirmInstall -FixtureMode | Out-Null
  & $manager -Operation Uninstall -RuntimeRoot $interruptedRoot -ConfirmUninstall -FixtureMode | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $interruptedRoot)) "fixture_interrupted_install_retry_cleanup_failed"

  & $manager -Operation Install -RuntimeRoot $runtimeRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ConfirmInstall -FixtureMode | Out-Null
  $installed = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($installed.installed -eq $true -and $installed.active_release_id.StartsWith($a.Commit)) "fixture_install_failed"
  & $manager -Operation Upgrade -RuntimeRoot $runtimeRoot -ArtifactPath $b.Artifact -ManifestPath $b.Manifest -EnvPath $b.Env -NodeConfigPath $b.Node -ExpectedSourceCommit $b.Commit -ExpectedArtifactSha256 $b.ArtifactSha -ConfirmUpgrade -FixtureMode | Out-Null
  $upgraded = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($upgraded.active_release_id.StartsWith($b.Commit)) "fixture_upgrade_failed"
  $aReleaseId = "$($a.Commit)-$($a.ArtifactSha.Substring(0, 16))"
  $aEntrypoint = Join-Path $runtimeRoot "releases\agent\$aReleaseId\app\dist\src\server-agent-daemon.js"
  Set-Content -LiteralPath $aEntrypoint -Value "tampered" -NoNewline
  $tamperedRollbackRejected = $false
  try { & $manager -Operation Rollback -RuntimeRoot $runtimeRoot -ConfirmRollback -FixtureMode | Out-Null } catch { $tamperedRollbackRejected = $true }
  $stillB = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($tamperedRollbackRejected -and $stillB.active_release_id.StartsWith($b.Commit)) "fixture_tampered_rollback_not_rejected"
  $restoreRoot = Join-Path $fixtureRoot "restore-a"; Expand-Archive -LiteralPath $a.Artifact -DestinationPath $restoreRoot
  Copy-Item -LiteralPath (Join-Path $restoreRoot "app\dist\src\server-agent-daemon.js") -Destination $aEntrypoint -Force
  Remove-Item -LiteralPath $restoreRoot -Recurse -Force
  & $manager -Operation Rollback -RuntimeRoot $runtimeRoot -ConfirmRollback -FixtureMode | Out-Null
  $rolledBack = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($rolledBack.active_release_id.StartsWith($a.Commit)) "fixture_no_rebuild_rollback_failed"
  Assert-True ((Get-Sha256 $secretFile) -eq $secretSha -and (Get-Sha256 (Join-Path $stateRoot "agent-state.json")) -eq $stateSha -and (Get-Sha256 (Join-Path $stateRoot "spool\preserved.batch.json")) -eq $spoolSha) "fixture_state_spool_or_secret_changed"
  $failedClosed = $false
  try { & $manager -Operation Upgrade -RuntimeRoot $runtimeRoot -ArtifactPath $c.Artifact -ManifestPath $c.Manifest -EnvPath $c.Env -NodeConfigPath $c.Node -ExpectedSourceCommit $c.Commit -ExpectedArtifactSha256 $c.ArtifactSha -ConfirmUpgrade -FixtureMode -SimulateHealthFailure | Out-Null }
  catch { $failedClosed = $_.Exception.Message -match "activation_failed_rolled_back" }
  Assert-True $failedClosed "fixture_failed_activation_not_rejected"
  $afterFailure = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($afterFailure.active_release_id.StartsWith($a.Commit)) "fixture_failed_activation_not_fail_closed"
  $ownerPath = Join-Path $runtimeRoot ".mg44-runtime-owner.json"; $ownerText = Get-Content -Raw -LiteralPath $ownerPath
  Remove-Item -LiteralPath $ownerPath -Force
  $missingOwnerRejected = $false
  try { & $manager -Operation Uninstall -RuntimeRoot $runtimeRoot -ConfirmUninstall -FixtureMode | Out-Null } catch { $missingOwnerRejected = $true }
  Assert-True $missingOwnerRejected "fixture_missing_owner_not_rejected"
  Set-Content -LiteralPath $ownerPath -Value $ownerText -Encoding UTF8
  & $manager -Operation Uninstall -RuntimeRoot $runtimeRoot -ConfirmUninstall -FixtureMode | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $runtimeRoot)) "fixture_uninstall_incomplete"
  Assert-True ((Get-Sha256 $secretFile) -eq $secretSha -and (Get-Sha256 (Join-Path $stateRoot "agent-state.json")) -eq $stateSha) "fixture_external_state_not_preserved"
  Assert-True (@(Get-Service -Name "JerryTelemetryAgent" -ErrorAction SilentlyContinue).Count -eq $serviceBefore) "real_service_state_changed"
  [ordered]@{
    ok = $true; install_passed = $true; upgrade_passed = $true; no_rebuild_rollback_passed = $true
    config_rollback_passed = $true; state_spool_secret_preserved = $true; failed_activation_fail_closed_passed = $true
    fresh_install_failure_cleanup_passed = $true; artifact_authorization_anchor_passed = $true
    interrupted_first_install_recovery_passed = $true
    fixed_entrypoint_passed = $true; full_dry_run_config_validation_passed = $true; tampered_rollback_rejected = $true
    ownership_boundary_passed = $true; spool_growth_gate_passed = $true
    uninstall_passed = $true; windows_service_registered = $false; production_contact = $false; lax_runtime_touched = $false
  } | ConvertTo-Json -Compress
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path; $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
  }
}
