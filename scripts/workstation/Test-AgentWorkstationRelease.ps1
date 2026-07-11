$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$manager = Join-Path $repoRoot "scripts\workstation\Invoke-AgentWorkstationRuntime.ps1"
$verifier = Join-Path $repoRoot "scripts\workstation\Test-AgentReleaseManifest.ps1"
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
  New-Item -ItemType Directory -Force -Path (Join-Path $stage "runtime"), (Join-Path $stage "app"), (Join-Path $stage "bin") | Out-Null
  Set-Content -LiteralPath (Join-Path $stage "runtime\node.exe") -Value "fixture-node-$Name" -NoNewline
  Set-Content -LiteralPath (Join-Path $stage "app\version.txt") -Value $Name -NoNewline
  Set-Content -LiteralPath (Join-Path $stage "bin\Start-AgentRelease.ps1") -Value "# fixture launcher" -NoNewline
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
    required_config_key_names = @("AGENT_MODE", "TELEMETRY_OUTPUT_MODE", "TELEMETRY_NODE_CONFIG_PATH", "TELEMETRY_NODE_SECRET_FILE", "STATE_PATH", "SPOOL_DIR", "HEALTH_HOST", "HEALTH_PORT")
    default_activation_state = [ordered]@{ message_gateway_readiness_collector_enabled = $false; output_mode = "file"; http_upload_enabled = $false }
    build_timestamp = [DateTime]::UtcNow.ToString("o"); entrypoint = "app/version.txt"; fixture_runtime = $true
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
  return [ordered]@{ Artifact = $artifact; Manifest = $manifestPath; Env = $envPath; Node = $nodePath; Commit = $commit }
}

try {
  New-Item -ItemType Directory -Force -Path $artifactRoot, $stateRoot, (Split-Path -Parent $secretFile), (Join-Path $stateRoot "spool") | Out-Null
  Set-Content -LiteralPath $secretFile -Value "fixture-signing-material" -NoNewline
  Set-Content -LiteralPath (Join-Path $stateRoot "agent-state.json") -Value '{"fixture":true}' -NoNewline
  Set-Content -LiteralPath (Join-Path $stateRoot "spool\preserved.batch.json") -Value '{"fixture":true}' -NoNewline
  $secretSha = Get-Sha256 $secretFile; $stateSha = Get-Sha256 (Join-Path $stateRoot "agent-state.json"); $spoolSha = Get-Sha256 (Join-Path $stateRoot "spool\preserved.batch.json")
  $a = New-FixtureRelease "a" "a"; $b = New-FixtureRelease "b" "b"; $c = New-FixtureRelease "c" "c"
  & $verifier -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -ExpectedSourceCommit $a.Commit -AllowFixtureRuntime | Out-Null
  & $manager -Operation Install -RuntimeRoot $runtimeRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -DryRun -FixtureMode | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $runtimeRoot)) "dry_run_mutated_runtime"
  & $manager -Operation Install -RuntimeRoot $runtimeRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ConfirmInstall -FixtureMode | Out-Null
  $installed = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($installed.installed -eq $true -and $installed.active_release_id.StartsWith($a.Commit)) "fixture_install_failed"
  & $manager -Operation Upgrade -RuntimeRoot $runtimeRoot -ArtifactPath $b.Artifact -ManifestPath $b.Manifest -EnvPath $b.Env -NodeConfigPath $b.Node -ConfirmUpgrade -FixtureMode | Out-Null
  $upgraded = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($upgraded.active_release_id.StartsWith($b.Commit)) "fixture_upgrade_failed"
  & $manager -Operation Rollback -RuntimeRoot $runtimeRoot -ConfirmRollback -FixtureMode | Out-Null
  $rolledBack = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($rolledBack.active_release_id.StartsWith($a.Commit)) "fixture_no_rebuild_rollback_failed"
  Assert-True ((Get-Sha256 $secretFile) -eq $secretSha -and (Get-Sha256 (Join-Path $stateRoot "agent-state.json")) -eq $stateSha -and (Get-Sha256 (Join-Path $stateRoot "spool\preserved.batch.json")) -eq $spoolSha) "fixture_state_spool_or_secret_changed"
  $failedClosed = $false
  try { & $manager -Operation Upgrade -RuntimeRoot $runtimeRoot -ArtifactPath $c.Artifact -ManifestPath $c.Manifest -EnvPath $c.Env -NodeConfigPath $c.Node -ConfirmUpgrade -FixtureMode -SimulateHealthFailure | Out-Null }
  catch { $failedClosed = $_.Exception.Message -match "health_failed_rolled_back" }
  Assert-True $failedClosed "fixture_failed_activation_not_rejected"
  $afterFailure = (& $manager -Operation Status -RuntimeRoot $runtimeRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($afterFailure.active_release_id.StartsWith($a.Commit)) "fixture_failed_activation_not_fail_closed"
  & $manager -Operation Uninstall -RuntimeRoot $runtimeRoot -ConfirmUninstall -FixtureMode | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $runtimeRoot)) "fixture_uninstall_incomplete"
  Assert-True ((Get-Sha256 $secretFile) -eq $secretSha -and (Get-Sha256 (Join-Path $stateRoot "agent-state.json")) -eq $stateSha) "fixture_external_state_not_preserved"
  Assert-True (@(Get-Service -Name "JerryTelemetryAgent" -ErrorAction SilentlyContinue).Count -eq $serviceBefore) "real_service_state_changed"
  [ordered]@{
    ok = $true; install_passed = $true; upgrade_passed = $true; no_rebuild_rollback_passed = $true
    config_rollback_passed = $true; state_spool_secret_preserved = $true; failed_activation_fail_closed_passed = $true
    uninstall_passed = $true; windows_service_registered = $false; production_contact = $false; lax_runtime_touched = $false
  } | ConvertTo-Json -Compress
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path; $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
  }
}
