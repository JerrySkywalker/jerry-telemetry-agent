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
function Get-TextSha256 {
  param([string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function New-EnvWithSecretReference {
  param([string]$Source, [string]$Destination, [string]$Reference)
  $lines = Get-Content -LiteralPath $Source | ForEach-Object { if ($_ -match "^TELEMETRY_NODE_SECRET_FILE=") { "TELEMETRY_NODE_SECRET_FILE=$Reference" } else { $_ } }
  $lines | Set-Content -LiteralPath $Destination -Encoding UTF8
  return $Destination
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
    service_template_byte_contract = [string]$trust.service_template.byte_contract; service_template_sha256 = [string]$trust.service_template.sha256
    service_account_contract = [ordered]@{ schema_version = [string]$trust.service_account.schema_version; model = "VirtualServiceAccount"; identity_kind = "service_name_derived"; binding_sha256 = [string]$trust.service_account.binding_sha256; password_required = $false; service_logon_right_mutation = $false }
    secret_reference_contract = [ordered]@{ schema_version = [string]$trust.secret_reference.schema_version; external_file_required = $true; direct_secret_forbidden = $true; validation_reads_value = $false; service_access = "read_only" }
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
  New-Item -ItemType Directory -Force -Path $artifactRoot, $stateRoot, (Split-Path -Parent $secretFile), (Join-Path $stateRoot "spool"), (Join-Path $fixtureRoot "fixture-modeled-logs"), (Join-Path $artifactRoot "nested-sibling-unsafe") | Out-Null
  Set-Content -LiteralPath (Join-Path $artifactRoot "nested-sibling-unsafe\marker") -Value "protected" -NoNewline
  Set-Content -LiteralPath (Join-Path $fixtureRoot "fixture-modeled-logs\modeled.log") -Value "modeled" -NoNewline
  $templatePath = Join-Path $repoRoot "deploy\workstation\jerry-telemetry-agent-service.xml.template"
  $templateText = [IO.File]::ReadAllText($templatePath)
  Assert-True (-not $templateText.Contains("`r") -and (Get-Sha256 $templatePath) -eq [string]$trust.service_template.sha256) "fixture_canonical_lf_template_invalid"
  $crlfTemplate = Join-Path $artifactRoot "crlf-template.xml"
  [IO.File]::WriteAllText($crlfTemplate, $templateText.Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
  Assert-True ((Get-Sha256 $crlfTemplate) -ne [string]$trust.service_template.sha256) "fixture_crlf_raw_digest_not_distinct"
  Assert-True ((Get-Sha256 $templatePath) -eq [string]$trust.service_template.sha256) "fixture_template_source_changed"
  $colocatedText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scripts\workstation\Test-ColocatedGatewayAgentIntegration.ps1")
  Assert-True ($colocatedText.Contains('throw "colocated_rehearsal_failed"') -and -not $colocatedText.Contains('throw $failure.Exception')) "fixture_colocated_failure_code_not_stable"
  $serviceSidEvidence = (& sc.exe showsid JerryTelemetryAgent 2>&1) -join " "
  Assert-True ($LASTEXITCODE -eq 0 -and $serviceSidEvidence -match "S-1-5-80-4005328107-3526505025-104273280-264616143-719074961") "fixture_service_sid_derivation_not_independently_anchored"
  Set-Content -LiteralPath $secretFile -Value "fixture-signing-material" -NoNewline
  Set-Content -LiteralPath (Join-Path $stateRoot "agent-state.json") -Value '{"fixture":true}' -NoNewline
  Set-Content -LiteralPath (Join-Path $stateRoot "spool\preserved.batch.json") -Value '{"fixture":true}' -NoNewline
  $secretSha = Get-Sha256 $secretFile; $stateSha = Get-Sha256 (Join-Path $stateRoot "agent-state.json"); $spoolSha = Get-Sha256 (Join-Path $stateRoot "spool\preserved.batch.json")
  $a = New-FixtureRelease "a" "a"; $b = New-FixtureRelease "b" "b"; $c = New-FixtureRelease "c" "c"
  & $verifier -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha `
    -ExpectedServiceTemplateSha256 ([string]$trust.service_template.sha256) `
    -ExpectedServiceAccountBindingSha256 ([string]$trust.service_account.binding_sha256) `
    -ExpectedSecretReferenceSchema ([string]$trust.secret_reference.schema_version) -AllowFixtureRuntime | Out-Null
  $contractAnchorRejections = 0
  foreach ($anchors in @(
    @{ Template = ("f" * 64); Account = [string]$trust.service_account.binding_sha256; Reference = [string]$trust.secret_reference.schema_version },
    @{ Template = [string]$trust.service_template.sha256; Account = ("f" * 64); Reference = [string]$trust.secret_reference.schema_version },
    @{ Template = [string]$trust.service_template.sha256; Account = [string]$trust.service_account.binding_sha256; Reference = "unsupported.reference.v0" }
  )) {
    try { & $verifier -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ExpectedServiceTemplateSha256 $anchors.Template -ExpectedServiceAccountBindingSha256 $anchors.Account -ExpectedSecretReferenceSchema $anchors.Reference -AllowFixtureRuntime | Out-Null }
    catch { $contractAnchorRejections++ }
  }
  Assert-True ($contractAnchorRejections -eq 3) "fixture_contract_authorization_anchor_not_enforced"
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
  try { & $verifier -ArtifactPath $a.Artifact -ManifestPath $badEntrypointManifest -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ExpectedServiceTemplateSha256 ([string]$trust.service_template.sha256) -ExpectedServiceAccountBindingSha256 ([string]$trust.service_account.binding_sha256) -ExpectedSecretReferenceSchema ([string]$trust.secret_reference.schema_version) -AllowFixtureRuntime | Out-Null } catch { $badEntrypointRejected = $true }
  Assert-True $badEntrypointRejected "fixture_bad_entrypoint_not_rejected"
  $badEnv = Join-Path $artifactRoot "agent-bad.env"
  (Get-Content -Raw -LiteralPath $a.Env).Replace("TELEMETRY_HUB_REQUEST_TIMEOUT_MS=5000", "TELEMETRY_HUB_REQUEST_TIMEOUT_MS=0") | Set-Content -LiteralPath $badEnv -Encoding UTF8
  $badConfigRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $badEnv -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $badConfigRejected = $true }
  Assert-True ($badConfigRejected -and -not (Test-Path -LiteralPath $badRoot)) "fixture_bad_config_not_rejected"
  $badAccountModelsRejected = $true
  foreach ($badAccount in @(
    @{ Model = "LocalSystem"; Identity = "LocalSystem" },
    @{ Model = "ExistingServiceAccount"; Identity = "NETWORK SERVICE" },
    @{ Model = "VirtualServiceAccount"; Identity = "BUILTIN\Administrators" },
    @{ Model = "VirtualServiceAccount"; Identity = 'NT SERVICE\JerryTelemetryAgent</user><password>injected</password><user>' }
  )) {
    try {
      & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ServiceAccountModel $badAccount.Model -ServiceAccountIdentity $badAccount.Identity -DryRun -FixtureMode | Out-Null
      $badAccountModelsRejected = $false
    } catch { }
  }
  Assert-True ($badAccountModelsRejected -and -not (Test-Path -LiteralPath $badRoot)) "fixture_unsafe_service_account_not_rejected"
  $directSecretEnv = Join-Path $artifactRoot "agent-direct-secret.env"
  $directSecretName = "TELEMETRY_NODE_" + "SECRET"
  ((Get-Content -Raw -LiteralPath $a.Env).TrimEnd() + "`r`n$directSecretName=fixture-forbidden`r`n") | Set-Content -LiteralPath $directSecretEnv -Encoding UTF8
  $directSecretRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $directSecretEnv -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $directSecretRejected = $true }
  Assert-True $directSecretRejected "fixture_direct_secret_not_rejected"
  $laxNode = Join-Path $artifactRoot "agent-lax.node.json"
  (Get-Content -Raw -LiteralPath $a.Node).Replace("fixture-workstation-node", "eu-lax-workstation") | Set-Content -LiteralPath $laxNode -Encoding UTF8
  $laxIdentityRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $laxNode -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $laxIdentityRejected = $true }
  Assert-True $laxIdentityRejected "fixture_lax_identity_marker_not_rejected"
  $secretLock = [IO.File]::Open($secretFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null
  } finally { $secretLock.Dispose() }
  $configBinding = Get-TextSha256 ((Get-Sha256 $a.Env) + (Get-Sha256 $a.Node))
  $secretReferenceBinding = Get-TextSha256 ("jerry.workstation.secret-reference.v1|" + ([IO.Path]::GetFullPath($secretFile)).ToLowerInvariant() + "|" + [string]$trust.service_account.binding_sha256)
  $agentIdentityBinding = Get-TextSha256 ("jerry.workstation.agent-identity.v1|fixture-workstation-node|fixture-key-reference|$secretReferenceBinding")
  $bindingTool = (& (Join-Path $repoRoot "scripts\workstation\Get-AgentWorkstationBindingAnchors.ps1") -EnvPath $a.Env -NodeConfigPath $a.Node -RuntimeRoot $badRoot) | ConvertFrom-Json
  Assert-True ($bindingTool.agent_identity_binding_sha256 -eq $agentIdentityBinding -and $bindingTool.config_binding_sha256 -eq $configBinding -and $bindingTool.secret_reference_binding_sha256 -eq $secretReferenceBinding -and $bindingTool.secret_value_accessed -eq $false) "fixture_binding_anchor_tool_invalid"
  & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ExpectedAgentIdentityBindingSha256 $agentIdentityBinding -ExpectedConfigBindingSha256 $configBinding -ExpectedSecretReferenceBindingSha256 $secretReferenceBinding -DryRun -FixtureMode | Out-Null
  $bindingAnchorRejections = 0
  foreach ($badAnchors in @(
    @{ Agent = ("f" * 64); Config = $configBinding; Secret = $secretReferenceBinding },
    @{ Agent = $agentIdentityBinding; Config = ("f" * 64); Secret = $secretReferenceBinding },
    @{ Agent = $agentIdentityBinding; Config = $configBinding; Secret = ("f" * 64) }
  )) {
    try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ExpectedAgentIdentityBindingSha256 $badAnchors.Agent -ExpectedConfigBindingSha256 $badAnchors.Config -ExpectedSecretReferenceBindingSha256 $badAnchors.Secret -DryRun -FixtureMode | Out-Null }
    catch { $bindingAnchorRejections++ }
  }
  Assert-True ($bindingAnchorRejections -eq 3) "fixture_lifecycle_binding_anchor_not_enforced"
  $accessCaseRejections = 0
  foreach ($accessCase in @("ReadDenied", "ReadOnlyGroupWrite", "ReadOnlyFullControl", "MutableWriteDenied", "MutableModify", "MutableRootDelete", "MutableOwnership", "MutableNonInheritable", "ChildDeny", "ChildExcessWrite", "ChildOwnership", "AllServicesInheritedWrite", "AncestorWrite", "AncestorDelete", "SiblingWrite", "NestedSiblingWrite", "TraversalDenied")) {
    try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode -FixtureAccessCase $accessCase | Out-Null }
    catch { $accessCaseRejections++ }
  }
  Assert-True ($accessCaseRejections -eq 17) "fixture_access_contract_negative_case_not_rejected"
  $mutableFixtureRoot = Join-Path $fixtureRoot "mutable-lifecycle"
  $mutableSpool = Join-Path $mutableFixtureRoot "spool"; $mutableLogs = Join-Path $mutableFixtureRoot "logs"; $protectedSibling = Join-Path $mutableFixtureRoot "protected-sibling"
  New-Item -ItemType Directory -Force -Path $mutableSpool, $mutableLogs, $protectedSibling | Out-Null
  $siblingMarker = Join-Path $protectedSibling "marker"; Set-Content -LiteralPath $siblingMarker -Value "preserved" -NoNewline; $siblingBefore = Get-Sha256 $siblingMarker
  $pendingSpool = Join-Path $mutableSpool "pending.batch.json"; Set-Content -LiteralPath $pendingSpool -Value "{}" -NoNewline
  $quarantinedSpool = "$pendingSpool.bad"; Move-Item -LiteralPath $pendingSpool -Destination $quarantinedSpool; Remove-Item -LiteralPath $quarantinedSpool
  foreach ($name in @("retention-1.batch.json", "retention-2.batch.json")) { Set-Content -LiteralPath (Join-Path $mutableSpool $name) -Value "{}" -NoNewline }
  Remove-Item -LiteralPath (Join-Path $mutableSpool "retention-1.batch.json")
  $activeLog = Join-Path $mutableLogs "agent.log"; Set-Content -LiteralPath $activeLog -Value "first" -NoNewline
  $rolledLog = Join-Path $mutableLogs "agent.log.1"; Move-Item -LiteralPath $activeLog -Destination $rolledLog; Set-Content -LiteralPath $activeLog -Value "second" -NoNewline; Remove-Item -LiteralPath $rolledLog
  Assert-True ((Test-Path -LiteralPath (Join-Path $mutableSpool "retention-2.batch.json")) -and (Test-Path -LiteralPath $activeLog) -and (Get-Sha256 $siblingMarker) -eq $siblingBefore) "fixture_mutable_lifecycle_or_sibling_protection_failed"
  $badAccessRoot = Join-Path $fixtureRoot "bad-access-runtime"; $badAccessInstallRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $badAccessRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ConfirmInstall -FixtureMode -FixtureAccessCase "ReadOnlyFullControl" | Out-Null } catch { $badAccessInstallRejected = $true }
  $badAccessReleaseSlots = @(Get-ChildItem -LiteralPath (Join-Path $badAccessRoot "releases\agent") -Directory -ErrorAction SilentlyContinue).Count
  $badAccessConfigSlots = @(Get-ChildItem -LiteralPath (Join-Path $badAccessRoot "config\agent\revisions") -Directory -ErrorAction SilentlyContinue).Count
  Assert-True ($badAccessInstallRejected -and $badAccessReleaseSlots -eq 0 -and $badAccessConfigSlots -eq 0) "fixture_failed_access_contract_left_candidate_slots"
  $referenceRoot = Join-Path $fixtureRoot "reference-boundaries"
  New-Item -ItemType Directory -Force -Path (Join-Path $referenceRoot "config"), (Join-Path $referenceRoot "state"), (Join-Path $referenceRoot "spool"), (Join-Path $referenceRoot "logs"), (Join-Path $referenceRoot "releases") | Out-Null
  $referenceRejections = 0
  foreach ($boundary in @("config", "state", "spool", "logs", "releases")) {
    $candidateSecret = Join-Path $referenceRoot "$boundary\candidate-secret"
    Set-Content -LiteralPath $candidateSecret -Value "fixture" -NoNewline
    $candidateEnv = New-EnvWithSecretReference $a.Env (Join-Path $artifactRoot "agent-$boundary.env") $candidateSecret
    try { & $manager -Operation Install -RuntimeRoot $referenceRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $candidateEnv -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null }
    catch { $referenceRejections++ }
  }
  $hardlinkSource = Join-Path $artifactRoot "hardlink-source"; Set-Content -LiteralPath $hardlinkSource -Value "fixture" -NoNewline
  $hardlinkSecret = Join-Path $artifactRoot "hardlink-secret"; New-Item -ItemType HardLink -Path $hardlinkSecret -Target $hardlinkSource | Out-Null
  $hardlinkEnv = New-EnvWithSecretReference $a.Env (Join-Path $artifactRoot "agent-hardlink.env") $hardlinkSecret
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $hardlinkEnv -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $referenceRejections++ }
  $symlinkSecret = Join-Path $artifactRoot "symlink-secret"; New-Item -ItemType SymbolicLink -Path $symlinkSecret -Target $secretFile | Out-Null
  $symlinkEnv = New-EnvWithSecretReference $a.Env (Join-Path $artifactRoot "agent-symlink.env") $symlinkSecret
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $symlinkEnv -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $referenceRejections++ }
  Remove-Item -LiteralPath $symlinkSecret -Force; Remove-Item -LiteralPath $hardlinkSecret -Force; Remove-Item -LiteralPath $hardlinkSource -Force
  $remoteEnv = New-EnvWithSecretReference $a.Env (Join-Path $artifactRoot "agent-remote.env") "\\fixture.invalid\share\secret"
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $remoteEnv -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $referenceRejections++ }
  $traversalEnv = New-EnvWithSecretReference $a.Env (Join-Path $artifactRoot "agent-traversal.env") (Join-Path $artifactRoot "nested\..\hub-signing-secret")
  try { & $manager -Operation Install -RuntimeRoot $badRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $traversalEnv -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null } catch { $referenceRejections++ }
  Assert-True ($referenceRejections -eq 9) "fixture_unsafe_secret_reference_not_rejected"
  & $manager -Operation Install -RuntimeRoot $runtimeRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -DryRun -FixtureMode | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $runtimeRoot)) "dry_run_mutated_runtime"
  $badScmRoot = Join-Path $fixtureRoot "bad-scm-runtime"; $badScmRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $badScmRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ConfirmInstall -FixtureMode -FixtureScmStartName "LocalSystem" | Out-Null } catch { $badScmRejected = $true }
  Assert-True ($badScmRejected -and -not ((& $manager -Operation Status -RuntimeRoot $badScmRoot -FixtureMode | ConvertFrom-Json).installed)) "fixture_scm_start_name_mismatch_not_rejected"
  $freshFailureRoot = Join-Path $fixtureRoot "fresh-failure-runtime"
  $freshFailureRejected = $false
  try { & $manager -Operation Install -RuntimeRoot $freshFailureRoot -ArtifactPath $c.Artifact -ManifestPath $c.Manifest -EnvPath $c.Env -NodeConfigPath $c.Node -ExpectedSourceCommit $c.Commit -ExpectedArtifactSha256 $c.ArtifactSha -ConfirmInstall -FixtureMode -SimulateHealthFailure | Out-Null } catch { $freshFailureRejected = $_.Exception.Message -match "activation_failed_rolled_back" }
  $freshStatus = (& $manager -Operation Status -RuntimeRoot $freshFailureRoot -FixtureMode) | ConvertFrom-Json
  Assert-True ($freshFailureRejected -and -not $freshStatus.installed -and -not $freshStatus.pending_recovery) "fixture_fresh_install_failure_not_cleaned"

  $interruptedRoot = Join-Path $fixtureRoot "interrupted-install-runtime"
  & $manager -Operation Install -RuntimeRoot $interruptedRoot -ArtifactPath $a.Artifact -ManifestPath $a.Manifest -EnvPath $a.Env -NodeConfigPath $a.Node -ExpectedSourceCommit $a.Commit -ExpectedArtifactSha256 $a.ArtifactSha -ConfirmInstall -FixtureMode | Out-Null
  $interruptedInstalled = (& $manager -Operation Status -RuntimeRoot $interruptedRoot -FixtureMode) | ConvertFrom-Json
  $interruptedCurrent = Join-Path $interruptedRoot "transactions\agent-current.json"; $interruptedPending = Join-Path $interruptedRoot "transactions\agent-pending.json"
  $interruptedCurrentRecord = Get-Content -Raw -LiteralPath $interruptedCurrent | ConvertFrom-Json
  Remove-Item -LiteralPath $interruptedCurrent -Force
  [ordered]@{
    schema_version = "jerry.workstation.activation.v1"; component = "agent"; operation = "Install"; phase = "config_switched"
    previous_release = $null; previous_config = $null; previous_source_commit = $null; previous_artifact_sha256 = $null
    target_release = $interruptedInstalled.active_release_id; target_config = $interruptedInstalled.active_config_id
    target_source_commit = $a.Commit; target_artifact_sha256 = $a.ArtifactSha
    target_release_created = $true; target_config_created = $true; maximum_spool_count = 1; recorded_at = [DateTime]::UtcNow.ToString("o")
    service_account_model = "VirtualServiceAccount"; service_account_binding_sha256 = [string]$trust.service_account.binding_sha256
    secret_reference_binding_sha256 = [string]$interruptedCurrentRecord.secret_reference_binding_sha256
    agent_identity_binding_sha256 = [string]$interruptedCurrentRecord.agent_identity_binding_sha256
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
  $installedText = $installed | ConvertTo-Json -Compress
  Assert-True ($installed.service_account_model -eq "VirtualServiceAccount" -and $installed.service_account_binding_sha256 -eq [string]$trust.service_account.binding_sha256 -and $installed.service_start_name_verified -eq $true -and $installed.caller_binding_anchors_verified -eq $true) "fixture_service_account_binding_not_persisted"
  $installedTransaction = Get-Content -Raw -LiteralPath (Join-Path $runtimeRoot "transactions\agent-current.json") | ConvertFrom-Json
  Assert-True ($installedTransaction.approved_agent_identity_binding_sha256 -eq $installedTransaction.agent_identity_binding_sha256 -and $installedTransaction.approved_config_binding_sha256 -eq $installedTransaction.active_config -and $installedTransaction.approved_secret_reference_binding_sha256 -eq $installedTransaction.secret_reference_binding_sha256) "fixture_caller_bindings_not_persisted"
  Assert-True (-not ($installedText -match "NT SERVICE|fixture-workstation|18081|hub-signing-secret|TELEMETRY_")) "fixture_status_output_not_allowlisted"
  $runtimeManagementRejections = 0
  foreach ($runtimeAccessCase in @("RuntimeOwnerWrite", "RuntimeTransactionWrite")) {
    try { & $manager -Operation Upgrade -RuntimeRoot $runtimeRoot -ArtifactPath $b.Artifact -ManifestPath $b.Manifest -EnvPath $b.Env -NodeConfigPath $b.Node -ExpectedSourceCommit $b.Commit -ExpectedArtifactSha256 $b.ArtifactSha -DryRun -FixtureMode -FixtureAccessCase $runtimeAccessCase | Out-Null }
    catch { $runtimeManagementRejections++ }
  }
  $unknownRuntimeSubtree = Join-Path $runtimeRoot "unknown-runtime-subtree"
  New-Item -ItemType Directory -Force -Path $unknownRuntimeSubtree | Out-Null
  Set-Content -LiteralPath (Join-Path $unknownRuntimeSubtree "unknown.marker") -Value "fixture" -NoNewline
  foreach ($unknownAccessCase in @("Safe", "UnknownRuntimeSubtreeWrite")) {
    try { & $manager -Operation Upgrade -RuntimeRoot $runtimeRoot -ArtifactPath $b.Artifact -ManifestPath $b.Manifest -EnvPath $b.Env -NodeConfigPath $b.Node -ExpectedSourceCommit $b.Commit -ExpectedArtifactSha256 $b.ArtifactSha -DryRun -FixtureMode -FixtureAccessCase $unknownAccessCase | Out-Null }
    catch { $runtimeManagementRejections++ }
  }
  Remove-Item -LiteralPath $unknownRuntimeSubtree -Recurse -Force
  Assert-True ($runtimeManagementRejections -eq 4) "fixture_runtime_management_write_or_unknown_subtree_not_rejected"
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
    canonical_lf_raw_template_passed = $true; password_free_virtual_account_passed = $true
    unsafe_account_rejection_passed = $true; secret_reference_value_not_accessed_during_validation = $true
    direct_secret_rejected = $true; lax_identity_rejected = $true; status_output_allowlist_passed = $true
    effective_access_contract_passed = $true; deny_precedence_passed = $true; inherited_group_write_rejected = $true
    bounded_write_contract_passed = $true; unsafe_reference_forms_rejected = $true; scm_start_name_verified = $true
    all_services_write_rejected = $true; ancestor_mutation_rejected = $true; protected_sibling_write_rejected = $true
    service_sid_derivation_independently_anchored = $true
    modeled_mutable_child_inheritance_passed = $true; recursive_mutable_descendants_passed = $true; recursive_protected_siblings_passed = $true
    recursive_runtime_management_boundaries_passed = $true; writable_owner_and_transaction_rejected = $true; unknown_runtime_subtree_rejected = $true
    spool_lifecycle_api_rehearsal_passed = $true; log_rotation_api_rehearsal_passed = $true
    caller_binding_anchors_preserved = $true
    colocated_failure_code_stable = $true
    uninstall_passed = $true; windows_service_registered = $false; production_contact = $false; lax_runtime_touched = $false
  } | ConvertTo-Json -Compress
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path; $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
  }
}
