param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Install", "Upgrade", "Rollback", "Uninstall", "Status")]
  [string]$Operation,
  [Parameter(Mandatory = $true)][string]$RuntimeRoot,
  [string]$ArtifactPath,
  [string]$ManifestPath,
  [string]$EnvPath,
  [string]$NodeConfigPath,
  [string]$ExpectedSourceCommit,
  [string]$ExpectedArtifactSha256,
  [string]$ServiceWrapperPath,
  [string]$ServiceTemplatePath,
  [string]$AuthorizationId,
  [switch]$DryRun,
  [switch]$ConfirmInstall,
  [switch]$ConfirmUpgrade,
  [switch]$ConfirmRollback,
  [switch]$ConfirmUninstall,
  [switch]$FixtureMode,
  [switch]$SimulateHealthFailure
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$component = "agent"
$serviceName = "JerryTelemetryAgent"
$ownerSchema = "jerry.workstation.runtime-owner.v1"
$transactionSchema = "jerry.workstation.activation.v1"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$verifier = Join-Path $repoRoot "scripts\workstation\Test-AgentReleaseManifest.ps1"
$defaultTemplate = Join-Path $repoRoot "deploy\workstation\jerry-telemetry-agent-service.xml.template"
$trust = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "deploy\workstation\trusted-runtime.json") | ConvertFrom-Json

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
function Get-CombinedConfigIdentity {
  param([string]$EnvFile, [string]$NodeFile)
  Assert-True (Test-Path -LiteralPath $EnvFile -PathType Leaf) "agent_env_missing"
  Assert-True (Test-Path -LiteralPath $NodeFile -PathType Leaf) "agent_node_config_missing"
  return Get-TextSha256 ((Get-Sha256 $EnvFile) + (Get-Sha256 $NodeFile))
}
function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-FixtureRoot {
  param([string]$Path)
  $full = [IO.Path]::GetFullPath($Path); $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  Assert-True ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) "fixture_root_must_be_under_temp"
}
function Get-ActiveTarget {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $item = Get-Item -LiteralPath $Path -Force
  Assert-True ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "active_path_not_junction"
  return [string]$item.Target
}
function Remove-Junction {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $item = Get-Item -LiteralPath $Path -Force
  Assert-True ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "refusing_to_remove_non_junction"
  [IO.Directory]::Delete($item.FullName)
}
function Set-ActiveJunction {
  param([string]$ActivePath, [string]$TargetPath)
  Assert-True (Test-Path -LiteralPath $TargetPath -PathType Container) "junction_target_missing"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ActivePath) | Out-Null
  $next = "$ActivePath.next"; $old = "$ActivePath.old"
  foreach ($path in @($next, $old)) { if (Test-Path -LiteralPath $path) { Remove-Junction $path } }
  New-Item -ItemType Junction -Path $next -Target $TargetPath | Out-Null
  if (Test-Path -LiteralPath $ActivePath) { Move-Item -LiteralPath $ActivePath -Destination $old }
  Move-Item -LiteralPath $next -Destination $ActivePath
  if (Test-Path -LiteralPath $old) { Remove-Junction $old }
}
function Invoke-ServiceCommand {
  param([string]$Wrapper, [string]$Command)
  & $Wrapper $Command
  if ($LASTEXITCODE -ne 0) { throw "service_command_${Command}_failed" }
}
function Write-JsonAtomic {
  param([string]$Path, [hashtable]$Data)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $temporary = "$Path.tmp"
  $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Get-OwnerPath { return Join-Path $root ".mg44-runtime-owner.json" }
function Assert-OwnedRuntime {
  $path = Get-OwnerPath
  Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "runtime_owner_marker_missing"
  $owner = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
  Assert-True ($owner.schema_version -eq $ownerSchema) "runtime_owner_schema_invalid"
  Assert-True ($owner.component -eq $component -and $owner.service_name -eq $serviceName) "runtime_owner_component_mismatch"
  Assert-True ($owner.root_fingerprint -eq (Get-TextSha256 $root.ToLowerInvariant())) "runtime_owner_root_mismatch"
  Assert-True ([string]$owner.installation_id -match "^[0-9a-f]{32}$") "runtime_owner_installation_id_invalid"
}
function Initialize-OwnedRuntime {
  $path = Get-OwnerPath
  if (Test-Path -LiteralPath $path) { Assert-OwnedRuntime; return }
  $unexpected = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -ne ".agent-runtime.lock" })
  Assert-True ($unexpected.Count -eq 0) "runtime_root_not_empty_or_owned"
  Write-JsonAtomic $path @{
    schema_version = $ownerSchema; component = $component; service_name = $serviceName
    root_fingerprint = Get-TextSha256 $root.ToLowerInvariant(); installation_id = [guid]::NewGuid().ToString("N")
    lifecycle_state = "owned"; created_at = [DateTime]::UtcNow.ToString("o")
  }
}
function Invoke-ArtifactVerifier {
  param([string]$Artifact, [string]$Manifest, [string]$SourceCommit, [string]$ArtifactSha, [string]$ExtractedRoot)
  $arguments = @{
    ArtifactPath = $Artifact; ManifestPath = $Manifest; ExpectedSourceCommit = $SourceCommit; ExpectedArtifactSha256 = $ArtifactSha
    ExpectedRuntimeVersion = [string]$trust.node_runtime.version; ExpectedNodeArchiveSha256 = [string]$trust.node_runtime.sha256
    ExpectedServiceWrapperVersion = [string]$trust.service_wrapper.version; ExpectedServiceWrapperSha256 = [string]$trust.service_wrapper.sha256
    AllowFixtureRuntime = [bool]$FixtureMode
  }
  if ($ExtractedRoot) { $arguments["ExtractedRoot"] = $ExtractedRoot }
  & $verifier @arguments | Out-Null
}
function Assert-ArtifactAuthorization {
  Assert-True ($ArtifactPath -and $ManifestPath -and $EnvPath -and $NodeConfigPath) "artifact_manifest_configs_required"
  Assert-True ($ExpectedSourceCommit -match "^[0-9a-fA-F]{40}$") "expected_source_commit_required"
  Assert-True ($ExpectedArtifactSha256 -match "^[0-9a-fA-F]{64}$") "expected_artifact_sha256_required"
  Invoke-ArtifactVerifier $ArtifactPath $ManifestPath $ExpectedSourceCommit.ToLowerInvariant() $ExpectedArtifactSha256.ToLowerInvariant() $null
}
function Invoke-LauncherValidation {
  param([string]$ReleaseDir, [string]$EnvFile, [string]$NodeFile)
  $launcher = Join-Path $ReleaseDir "bin\Start-AgentRelease.ps1"
  Assert-True (Test-Path -LiteralPath $launcher -PathType Leaf) "release_launcher_missing"
  & $launcher -ReleaseRoot $ReleaseDir -EnvPath $EnvFile -NodeConfigPath $NodeFile -ValidateOnly -AllowFixtureRuntime:$FixtureMode -RequireSafeDefaults | Out-Null
}
function Test-CandidateArchive {
  Assert-ArtifactAuthorization
  $temporary = Join-Path ([IO.Path]::GetTempPath()) ("jta-candidate-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temporary | Out-Null
  try {
    Expand-Archive -LiteralPath $ArtifactPath -DestinationPath $temporary
    Invoke-ArtifactVerifier $ArtifactPath $ManifestPath $ExpectedSourceCommit.ToLowerInvariant() $ExpectedArtifactSha256.ToLowerInvariant() $temporary
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $temporary "release-manifest.json")
    Invoke-LauncherValidation $temporary $EnvPath $NodeConfigPath
  } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }
}
function Get-ReleaseMetadata {
  param([string]$ReleaseDir, [string]$ExpectedSource, [string]$ExpectedArtifact)
  Assert-True (Test-Path -LiteralPath $ReleaseDir -PathType Container) "release_slot_missing"
  $manifestFile = Join-Path $ReleaseDir "release-manifest.json"
  Assert-True (Test-Path -LiteralPath $manifestFile -PathType Leaf) "release_slot_manifest_missing"
  $manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json
  Assert-True ([string]$manifest.source_commit -eq $ExpectedSource) "release_slot_source_mismatch"
  Assert-True ([string]$manifest.artifact_sha256 -eq $ExpectedArtifact) "release_slot_artifact_mismatch"
  Assert-True ((Split-Path -Leaf $ReleaseDir) -eq "$ExpectedSource-$($ExpectedArtifact.Substring(0, 16))") "release_slot_identity_mismatch"
  return $manifest
}
function Test-InstalledSlot {
  param([string]$ReleaseDir, [string]$ConfigDir, [string]$ExpectedSource, [string]$ExpectedArtifact, [string]$ExpectedConfig)
  Get-ReleaseMetadata $ReleaseDir $ExpectedSource $ExpectedArtifact | Out-Null
  Assert-True (Test-Path -LiteralPath $ConfigDir -PathType Container) "config_revision_missing"
  Assert-True ((Split-Path -Leaf $ConfigDir) -eq $ExpectedConfig) "config_revision_identity_mismatch"
  $envFile = Join-Path $ConfigDir "agent.env"; $nodeFile = Join-Path $ConfigDir "node.json"
  Assert-True ((Get-CombinedConfigIdentity $envFile $nodeFile) -eq $ExpectedConfig) "config_revision_sha256_mismatch"
  Invoke-LauncherValidation $ReleaseDir $envFile $nodeFile
}
function Stage-Candidate {
  Assert-ArtifactAuthorization
  $source = $ExpectedSourceCommit.ToLowerInvariant(); $artifactSha = $ExpectedArtifactSha256.ToLowerInvariant()
  $configId = Get-CombinedConfigIdentity $EnvPath $NodeConfigPath
  $releaseId = "$source-$($artifactSha.Substring(0, 16))"
  $releaseDir = Join-Path $root "releases\agent\$releaseId"; $configDir = Join-Path $root "config\agent\revisions\$configId"
  $createdRelease = -not (Test-Path -LiteralPath $releaseDir); $createdConfig = -not (Test-Path -LiteralPath $configDir)
  if ($createdRelease) {
    $stage = "$releaseDir.staging"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
      Expand-Archive -LiteralPath $ArtifactPath -DestinationPath $stage
      Invoke-ArtifactVerifier $ArtifactPath $ManifestPath $source $artifactSha $stage
      Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $stage "release-manifest.json")
      Invoke-LauncherValidation $stage $EnvPath $NodeConfigPath
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $releaseDir) | Out-Null
      Move-Item -LiteralPath $stage -Destination $releaseDir
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
  }
  if ($createdConfig) {
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    Copy-Item -LiteralPath $EnvPath -Destination (Join-Path $configDir "agent.env")
    Copy-Item -LiteralPath $NodeConfigPath -Destination (Join-Path $configDir "node.json")
  }
  Test-InstalledSlot $releaseDir $configDir $source $artifactSha $configId
  return [ordered]@{
    release_id = $releaseId; release_dir = $releaseDir; config_id = $configId; config_dir = $configDir
    source_commit = $source; artifact_sha256 = $artifactSha; created_release = $createdRelease; created_config = $createdConfig
  }
}
function Get-EnvValue {
  param([string]$Path, [string]$Name)
  $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match ("^\s*" + [regex]::Escape($Name) + "\s*=") } | Select-Object -First 1
  if (-not $line) { return $null }
  return ($line -split "=", 2)[1].Trim()
}
function Get-SpoolCount {
  param([string]$ConfigDir)
  $spoolPath = Get-EnvValue (Join-Path $ConfigDir "agent.env") "SPOOL_DIR"
  if (-not $spoolPath -or -not (Test-Path -LiteralPath $spoolPath -PathType Container)) { return 0 }
  return @(Get-ChildItem -LiteralPath $spoolPath -File -ErrorAction SilentlyContinue).Count
}
function Test-AgentHealth {
  param([string]$ActiveRelease, [string]$ActiveConfig, [int]$MaximumSpoolCount, [switch]$Recovery)
  if ($SimulateHealthFailure -and -not $Recovery) { return $false }
  if ($FixtureMode) {
    return (Test-Path -LiteralPath (Join-Path $ActiveRelease "release-manifest.json")) -and
      (Test-Path -LiteralPath (Join-Path $ActiveConfig "agent.env")) -and
      (Get-SpoolCount $ActiveConfig) -le $MaximumSpoolCount
  }
  $port = Get-EnvValue (Join-Path $ActiveConfig "agent.env") "HEALTH_PORT"
  if (-not $port) { return $false }
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 1
      if ($health.ok -eq $true -and (Get-SpoolCount $ActiveConfig) -le $MaximumSpoolCount) { return $true }
    } catch { Start-Sleep -Milliseconds 250 }
  }
  return $false
}
function Get-CurrentTransactionPath { return Join-Path $root "transactions\agent-current.json" }
function Get-PendingTransactionPath { return Join-Path $root "transactions\agent-pending.json" }
function Read-Transaction {
  param([string]$Path)
  Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "transaction_missing"
  $value = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  Assert-True ($value.schema_version -eq $transactionSchema -and $value.component -eq $component) "transaction_invalid"
  return $value
}
function Write-PendingTransaction {
  param([hashtable]$Data)
  $Data["schema_version"] = $transactionSchema; $Data["component"] = $component; $Data["recorded_at"] = [DateTime]::UtcNow.ToString("o")
  Write-JsonAtomic (Get-PendingTransactionPath) $Data
}
function Write-CurrentTransaction {
  param([hashtable]$Data)
  $Data["schema_version"] = $transactionSchema; $Data["component"] = $component; $Data["recorded_at"] = [DateTime]::UtcNow.ToString("o")
  Write-JsonAtomic (Get-CurrentTransactionPath) $Data
}
function Remove-PendingTransaction { $path = Get-PendingTransactionPath; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
function Get-ActiveEvidence {
  $transaction = Read-Transaction (Get-CurrentTransactionPath)
  return [ordered]@{
    release_id = [string]$transaction.active_release; config_id = [string]$transaction.active_config
    source_commit = [string]$transaction.active_source_commit; artifact_sha256 = [string]$transaction.active_artifact_sha256
  }
}
function Assert-ActiveEvidence {
  param($Evidence)
  $releaseDir = Join-Path $root "releases\agent\$($Evidence.release_id)"; $configDir = Join-Path $root "config\agent\revisions\$($Evidence.config_id)"
  Test-InstalledSlot $releaseDir $configDir $Evidence.source_commit $Evidence.artifact_sha256 $Evidence.config_id
  Assert-True ((Get-ActiveTarget (Join-Path $root "active\agent")) -eq $releaseDir) "active_release_transaction_mismatch"
  Assert-True ((Get-ActiveTarget (Join-Path $root "config\agent\active")) -eq $configDir) "active_config_transaction_mismatch"
}
function Assert-NoPendingRecovery { Assert-True (-not (Test-Path -LiteralPath (Get-PendingTransactionPath))) "pending_activation_recovery_required" }

$root = [IO.Path]::GetFullPath($RuntimeRoot)
Assert-True ([IO.Path]::IsPathRooted($root)) "runtime_root_must_be_absolute"
Assert-True ($root -ne [IO.Path]::GetPathRoot($root)) "runtime_root_cannot_be_volume_root"
if ($FixtureMode) { Assert-FixtureRoot $root }
$confirm = switch ($Operation) {
  "Install" { [bool]$ConfirmInstall }; "Upgrade" { [bool]$ConfirmUpgrade }; "Rollback" { [bool]$ConfirmRollback }; "Uninstall" { [bool]$ConfirmUninstall }; default { $false }
}
if ($Operation -ne "Status") { Assert-True ($DryRun -xor $confirm) "exactly_one_dry_run_or_matching_confirmation_required" }

if ($Operation -eq "Status") {
  $owned = Test-Path -LiteralPath (Get-OwnerPath) -PathType Leaf
  if ($owned) { Assert-OwnedRuntime }
  $releaseTarget = Get-ActiveTarget (Join-Path $root "active\agent"); $configTarget = Get-ActiveTarget (Join-Path $root "config\agent\active")
  $manifest = if ($releaseTarget -and (Test-Path -LiteralPath (Join-Path $releaseTarget "release-manifest.json"))) { Get-Content -Raw -LiteralPath (Join-Path $releaseTarget "release-manifest.json") | ConvertFrom-Json } else { $null }
  [ordered]@{
    ok = $true; owned = $owned; installed = [bool]($releaseTarget -and $configTarget)
    active_release_id = if ($releaseTarget) { Split-Path -Leaf $releaseTarget } else { $null }
    active_config_id = if ($configTarget) { Split-Path -Leaf $configTarget } else { $null }
    source_commit = if ($manifest) { [string]$manifest.source_commit } else { $null }
    artifact_sha256 = if ($manifest) { [string]$manifest.artifact_sha256 } else { $null }
    runtime_version = if ($manifest) { [string]$manifest.runtime_version } else { $null }
    pending_spool_count = if ($configTarget) { Get-SpoolCount $configTarget } else { 0 }
    pending_recovery = Test-Path -LiteralPath (Get-PendingTransactionPath)
    service_identity = $serviceName; secret_values_printed = $false; lax_runtime_touched = $false
  } | ConvertTo-Json -Compress
  return
}

if ($DryRun) {
  if ($Operation -in @("Install", "Upgrade")) {
    Test-CandidateArchive
    if ($Operation -eq "Upgrade") { Assert-OwnedRuntime; Assert-NoPendingRecovery; Assert-ActiveEvidence (Get-ActiveEvidence) }
  } elseif ($Operation -eq "Rollback") {
    Assert-OwnedRuntime
    $record = if (Test-Path -LiteralPath (Get-PendingTransactionPath)) { Read-Transaction (Get-PendingTransactionPath) } else { Read-Transaction (Get-CurrentTransactionPath) }
    Assert-True ($record.previous_release -and $record.previous_config -and $record.previous_source_commit -and $record.previous_artifact_sha256) "rollback_previous_slot_missing"
    Test-InstalledSlot (Join-Path $root "releases\agent\$($record.previous_release)") (Join-Path $root "config\agent\revisions\$($record.previous_config)") ([string]$record.previous_source_commit) ([string]$record.previous_artifact_sha256) ([string]$record.previous_config)
  } else { Assert-OwnedRuntime; Assert-NoPendingRecovery }
  [ordered]@{ ok = $true; operation = $Operation; dry_run = $true; fixture_mode = [bool]$FixtureMode; mutation_performed = $false; service_registered = $false; production_contact = $false; lax_runtime_touched = $false } | ConvertTo-Json -Compress
  return
}

if (-not $FixtureMode) {
  Assert-True ($AuthorizationId -match "^[A-Za-z0-9._-]{8,128}$") "production_authorization_id_required"
  Assert-True (Test-Administrator) "administrator_required_for_service_mutation"
  Assert-True ($ServiceWrapperPath -and (Test-Path -LiteralPath $ServiceWrapperPath -PathType Leaf)) "service_wrapper_required"
  Assert-True ((Get-Sha256 $ServiceWrapperPath) -eq [string]$trust.service_wrapper.sha256) "service_wrapper_sha256_mismatch"
  Assert-True (-not $ServiceTemplatePath) "custom_service_template_forbidden"
  Assert-True ((Get-Sha256 $defaultTemplate) -eq [string]$trust.service_template.sha256) "service_template_sha256_mismatch"
}
if ($Operation -eq "Install") { if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null } }
else { Assert-True (Test-Path -LiteralPath $root -PathType Container) "runtime_root_missing" }

$lock = [IO.File]::Open((Join-Path $root ".agent-runtime.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  if ($Operation -eq "Install") { Initialize-OwnedRuntime } else { Assert-OwnedRuntime }
  if ($Operation -in @("Install", "Upgrade")) {
    Assert-NoPendingRecovery
    $candidate = Stage-Candidate
    $activeReleasePath = Join-Path $root "active\agent"; $activeConfigPath = Join-Path $root "config\agent\active"
    $previousReleaseDir = Get-ActiveTarget $activeReleasePath; $previousConfigDir = Get-ActiveTarget $activeConfigPath
    $previous = $null
    if ($Operation -eq "Install") { Assert-True (-not $previousReleaseDir -and -not $previousConfigDir) "agent_already_installed" }
    else { Assert-True ($previousReleaseDir -and $previousConfigDir) "agent_upgrade_requires_existing_release"; $previous = Get-ActiveEvidence; Assert-ActiveEvidence $previous }
    $spoolBefore = Get-SpoolCount $candidate.config_dir
    $pending = @{
      operation = $Operation; phase = "prepared"
      previous_release = if ($previous) { $previous.release_id } else { $null }; previous_config = if ($previous) { $previous.config_id } else { $null }
      previous_source_commit = if ($previous) { $previous.source_commit } else { $null }; previous_artifact_sha256 = if ($previous) { $previous.artifact_sha256 } else { $null }
      target_release = $candidate.release_id; target_config = $candidate.config_id; target_source_commit = $candidate.source_commit; target_artifact_sha256 = $candidate.artifact_sha256
      maximum_spool_count = $spoolBefore
    }
    Write-PendingTransaction $pending
    $serviceExe = Join-Path $root "services\agent\agent-service.exe"; $installedThisAttempt = $false
    try {
      if (-not $FixtureMode) {
        $serviceDir = Split-Path -Parent $serviceExe; $logDir = Join-Path $root "logs\agent"
        New-Item -ItemType Directory -Force -Path $serviceDir, $logDir | Out-Null
        Copy-Item -LiteralPath $ServiceWrapperPath -Destination $serviceExe -Force
        $xml = Get-Content -Raw -LiteralPath $defaultTemplate
        $xml = $xml.Replace("__ACTIVE_ROOT__", $activeReleasePath).Replace("__ENV_PATH__", (Join-Path $activeConfigPath "agent.env")).Replace("__NODE_CONFIG_PATH__", (Join-Path $activeConfigPath "node.json")).Replace("__LOG_PATH__", $logDir)
        Assert-True (-not ($xml -match "__[A-Z_]+__")) "service_template_placeholder_unresolved"
        $xml | Set-Content -LiteralPath (Join-Path $serviceDir "agent-service.xml") -Encoding UTF8
        if ($Operation -eq "Upgrade") { Invoke-ServiceCommand $serviceExe "stop" }
      }
      $pending["phase"] = "service_stopped"; Write-PendingTransaction $pending
      Set-ActiveJunction $activeReleasePath $candidate.release_dir; $pending["phase"] = "release_switched"; Write-PendingTransaction $pending
      Set-ActiveJunction $activeConfigPath $candidate.config_dir; $pending["phase"] = "config_switched"; Write-PendingTransaction $pending
      if (-not $FixtureMode) { if ($Operation -eq "Install") { Invoke-ServiceCommand $serviceExe "install"; $installedThisAttempt = $true }; Invoke-ServiceCommand $serviceExe "start" }
      $pending["phase"] = "service_started"; Write-PendingTransaction $pending
      Assert-True (Test-AgentHealth $activeReleasePath $activeConfigPath $spoolBefore) "agent_activation_health_or_spool_failed"
      Test-InstalledSlot $candidate.release_dir $candidate.config_dir $candidate.source_commit $candidate.artifact_sha256 $candidate.config_id
      Write-CurrentTransaction @{
        operation = $Operation
        previous_release = if ($previous) { $previous.release_id } else { $null }; previous_config = if ($previous) { $previous.config_id } else { $null }
        previous_source_commit = if ($previous) { $previous.source_commit } else { $null }; previous_artifact_sha256 = if ($previous) { $previous.artifact_sha256 } else { $null }
        active_release = $candidate.release_id; active_config = $candidate.config_id; active_source_commit = $candidate.source_commit; active_artifact_sha256 = $candidate.artifact_sha256
        state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true; spool_count_after = Get-SpoolCount $candidate.config_dir
      }
      Remove-PendingTransaction
    } catch {
      if (-not $FixtureMode -and (Test-Path -LiteralPath $serviceExe)) { try { Invoke-ServiceCommand $serviceExe "stop" } catch { } }
      $recovered = $false
      if ($previous) {
        try {
          Set-ActiveJunction $activeReleasePath $previousReleaseDir; Set-ActiveJunction $activeConfigPath $previousConfigDir
          $previousSpool = Get-SpoolCount $previousConfigDir
          if (-not $FixtureMode) { Invoke-ServiceCommand $serviceExe "start" }
          $recovered = Test-AgentHealth $activeReleasePath $activeConfigPath $previousSpool -Recovery
          if ($recovered) { Assert-ActiveEvidence $previous }
        } catch { $recovered = $false }
      } else {
        try {
          if (-not $FixtureMode -and (Test-Path -LiteralPath $serviceExe)) { try { Invoke-ServiceCommand $serviceExe "uninstall" } catch { } }
          foreach ($junction in @($activeReleasePath, $activeConfigPath)) { if (Test-Path -LiteralPath $junction) { Remove-Junction $junction } }
          $serviceDir = Join-Path $root "services\agent"; if (Test-Path -LiteralPath $serviceDir) { Remove-Item -LiteralPath $serviceDir -Recurse -Force }
          if ($candidate.created_release -and (Test-Path -LiteralPath $candidate.release_dir)) { Remove-Item -LiteralPath $candidate.release_dir -Recurse -Force }
          if ($candidate.created_config -and (Test-Path -LiteralPath $candidate.config_dir)) { Remove-Item -LiteralPath $candidate.config_dir -Recurse -Force }
          $recovered = (-not (Test-Path -LiteralPath $activeReleasePath)) -and (-not (Test-Path -LiteralPath $activeConfigPath))
        } catch { $recovered = $false }
      }
      if ($recovered) { Remove-PendingTransaction; throw "agent_activation_failed_rolled_back" }
      throw "agent_activation_failed_recovery_required"
    }
    [ordered]@{ ok = $true; operation = $Operation; active_release = $candidate.release_id; active_config = $candidate.config_id; health = "pass"; spool_growth = 0; fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
    return
  }
  if ($Operation -eq "Rollback") {
    $pendingPath = Get-PendingTransactionPath; $recoveringPending = Test-Path -LiteralPath $pendingPath
    $record = if ($recoveringPending) { Read-Transaction $pendingPath } else { Read-Transaction (Get-CurrentTransactionPath) }
    Assert-True ($record.previous_release -and $record.previous_config -and $record.previous_source_commit -and $record.previous_artifact_sha256) "rollback_previous_slot_missing"
    $target = [ordered]@{ release_id = [string]$record.previous_release; config_id = [string]$record.previous_config; source_commit = [string]$record.previous_source_commit; artifact_sha256 = [string]$record.previous_artifact_sha256 }
    $targetReleaseDir = Join-Path $root "releases\agent\$($target.release_id)"; $targetConfigDir = Join-Path $root "config\agent\revisions\$($target.config_id)"
    Test-InstalledSlot $targetReleaseDir $targetConfigDir $target.source_commit $target.artifact_sha256 $target.config_id
    $current = if ($recoveringPending) { $null } else { Get-ActiveEvidence }; if ($current) { Assert-ActiveEvidence $current }
    $activeReleasePath = Join-Path $root "active\agent"; $activeConfigPath = Join-Path $root "config\agent\active"
    if (-not $recoveringPending) {
      Write-PendingTransaction @{
        operation = "Rollback"; phase = "prepared"
        previous_release = $current.release_id; previous_config = $current.config_id; previous_source_commit = $current.source_commit; previous_artifact_sha256 = $current.artifact_sha256
        target_release = $target.release_id; target_config = $target.config_id; target_source_commit = $target.source_commit; target_artifact_sha256 = $target.artifact_sha256
      }
    }
    $serviceExe = Join-Path $root "services\agent\agent-service.exe"; $targetSpool = Get-SpoolCount $targetConfigDir
    try {
      if (-not $FixtureMode) { Invoke-ServiceCommand $serviceExe "stop" }
      Set-ActiveJunction $activeReleasePath $targetReleaseDir; Set-ActiveJunction $activeConfigPath $targetConfigDir
      if (-not $FixtureMode) { Invoke-ServiceCommand $serviceExe "start" }
      Assert-True (Test-AgentHealth $activeReleasePath $activeConfigPath $targetSpool) "rollback_health_or_spool_failed"
      Test-InstalledSlot $targetReleaseDir $targetConfigDir $target.source_commit $target.artifact_sha256 $target.config_id
      Write-CurrentTransaction @{
        operation = "Rollback"
        previous_release = if ($current) { $current.release_id } else { [string]$record.target_release }; previous_config = if ($current) { $current.config_id } else { [string]$record.target_config }
        previous_source_commit = if ($current) { $current.source_commit } else { [string]$record.target_source_commit }; previous_artifact_sha256 = if ($current) { $current.artifact_sha256 } else { [string]$record.target_artifact_sha256 }
        active_release = $target.release_id; active_config = $target.config_id; active_source_commit = $target.source_commit; active_artifact_sha256 = $target.artifact_sha256
        state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true; spool_count_after = Get-SpoolCount $targetConfigDir
      }
      Remove-PendingTransaction
    } catch {
      if ($current) {
        $restored = $false
        try {
          if (-not $FixtureMode) { try { Invoke-ServiceCommand $serviceExe "stop" } catch { } }
          $currentReleaseDir = Join-Path $root "releases\agent\$($current.release_id)"; $currentConfigDir = Join-Path $root "config\agent\revisions\$($current.config_id)"
          Set-ActiveJunction $activeReleasePath $currentReleaseDir; Set-ActiveJunction $activeConfigPath $currentConfigDir
          $currentSpool = Get-SpoolCount $currentConfigDir
          if (-not $FixtureMode) { Invoke-ServiceCommand $serviceExe "start" }
          Assert-True (Test-AgentHealth $activeReleasePath $activeConfigPath $currentSpool -Recovery) "rollback_restore_health_failed"
          Remove-PendingTransaction; $restored = $true
        } catch { $restored = $false }
        if ($restored) { throw "rollback_failed_original_restored" }
      }
      throw "rollback_failed_recovery_required"
    }
    [ordered]@{ ok = $true; operation = "Rollback"; active_release = $target.release_id; no_rebuild = $true; state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true; fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
    return
  }
  if ($Operation -eq "Uninstall") {
    Assert-NoPendingRecovery
    $serviceExe = Join-Path $root "services\agent\agent-service.exe"
    if (-not $FixtureMode -and (Test-Path -LiteralPath $serviceExe)) { try { Invoke-ServiceCommand $serviceExe "stop" } catch { }; Invoke-ServiceCommand $serviceExe "uninstall" }
    foreach ($junction in @((Join-Path $root "active\agent"), (Join-Path $root "config\agent\active"))) { if (Test-Path -LiteralPath $junction) { Remove-Junction $junction } }
    $serviceDir = Join-Path $root "services\agent"; if (Test-Path -LiteralPath $serviceDir) { Remove-Item -LiteralPath $serviceDir -Recurse -Force }
    if ($FixtureMode) { $lock.Dispose(); $lock = $null; Remove-Item -LiteralPath $root -Recurse -Force }
    else {
      $ownerPath = Get-OwnerPath; $owner = Get-Content -Raw -LiteralPath $ownerPath | ConvertFrom-Json
      Write-JsonAtomic $ownerPath @{
        schema_version = $ownerSchema; component = $component; service_name = $serviceName
        root_fingerprint = Get-TextSha256 $root.ToLowerInvariant(); installation_id = [string]$owner.installation_id
        lifecycle_state = "uninstalled_data_preserved"; updated_at = [DateTime]::UtcNow.ToString("o")
      }
    }
    [ordered]@{ ok = $true; operation = "Uninstall"; service_removed = $true; active_boundaries_removed = $true; persistent_data_preserved = (-not $FixtureMode); fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
    return
  }
} finally { if ($null -ne $lock) { $lock.Dispose() } }
