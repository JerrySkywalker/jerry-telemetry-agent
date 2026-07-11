param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Install", "Upgrade", "Rollback", "Uninstall", "Status")]
  [string]$Operation,
  [Parameter(Mandatory = $true)][string]$RuntimeRoot,
  [string]$ArtifactPath,
  [string]$ManifestPath,
  [string]$EnvPath,
  [string]$NodeConfigPath,
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
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$verifier = Join-Path $repoRoot "scripts\workstation\Test-AgentReleaseManifest.ps1"
$defaultTemplate = Join-Path $repoRoot "deploy\workstation\jerry-telemetry-agent-service.xml.template"
$trust = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "deploy\workstation\trusted-runtime.json") | ConvertFrom-Json

function Assert-True { param([bool]$Condition, [string]$Code); if (-not $Condition) { throw $Code } }
function Get-Sha256 {
  param([string]$Path)
  $stream = [IO.File]::OpenRead($Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose(); $stream.Dispose() }
}
function Get-CombinedConfigIdentity {
  param([string]$EnvFile, [string]$NodeFile)
  Assert-True (Test-Path -LiteralPath $EnvFile -PathType Leaf) "agent_env_missing"
  Assert-True (Test-Path -LiteralPath $NodeFile -PathType Leaf) "agent_node_config_missing"
  $envText = Get-Content -Raw -LiteralPath $EnvFile
  Assert-True ($envText -match "(?m)^\s*TELEMETRY_OUTPUT_MODE\s*=\s*file\s*$") "agent_output_must_default_file_only"
  Assert-True ($envText -match "(?m)^\s*HEALTH_HOST\s*=\s*(127\.0\.0\.1|localhost|::1)\s*$") "agent_health_must_be_loopback"
  Assert-True ($envText -match "(?m)^\s*TELEMETRY_NODE_SECRET_FILE\s*=\s*.+$") "agent_secret_file_reference_missing"
  Assert-True (-not ($envText -match "(?m)^\s*TELEMETRY_NODE_SECRET\s*=")) "agent_direct_secret_forbidden"
  $node = Get-Content -Raw -LiteralPath $NodeFile | ConvertFrom-Json
  Assert-True ([string]$node.node_id -and [string]$node.node_id -ne "us-lax-pro-01") "agent_lax_identity_reuse_forbidden"
  Assert-True ($node.role -eq "message-gateway" -and $node.provider -eq "local") "agent_node_role_invalid"
  $collector = @($node.collectors | Where-Object { $_.name -eq "message-gateway-readiness" })
  Assert-True ($collector.Count -eq 1 -and $collector[0].enabled -eq $false) "agent_collector_must_default_disabled"
  $target = [Uri]$collector[0].target.url
  Assert-True (@("127.0.0.1", "localhost", "[::1]", "::1") -contains $target.Host) "agent_target_must_be_loopback"
  Assert-True ([int]$collector[0].target.timeout_ms -le 2000) "agent_target_timeout_too_large"
  $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Sha256 $EnvFile) + (Get-Sha256 $NodeFile))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-FixtureRoot {
  param([string]$Path)
  $full = [IO.Path]::GetFullPath($Path)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
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
function Get-EnvValue {
  param([string]$Path, [string]$Name)
  $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match ("^\s*" + [regex]::Escape($Name) + "\s*=") } | Select-Object -First 1
  if (-not $line) { return $null }
  return ($line -split "=", 2)[1].Trim()
}
function Test-AgentHealth {
  param([string]$ActiveRelease, [string]$ActiveConfig)
  if ($SimulateHealthFailure) { return $false }
  if ($FixtureMode) { return (Test-Path -LiteralPath (Join-Path $ActiveRelease "release-manifest.json")) -and (Test-Path -LiteralPath (Join-Path $ActiveConfig "agent.env")) }
  $port = Get-EnvValue (Join-Path $ActiveConfig "agent.env") "HEALTH_PORT"
  if (-not $port) { return $false }
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 1
      if ($health.ok -eq $true) { return $true }
    } catch { Start-Sleep -Milliseconds 250 }
  }
  return $false
}
function Write-Transaction {
  param([hashtable]$Data)
  $transactions = Join-Path $root "transactions"
  New-Item -ItemType Directory -Force -Path $transactions | Out-Null
  $Data["recorded_at"] = [DateTime]::UtcNow.ToString("o"); $Data["component"] = $component
  $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $transactions "agent-current.json") -Encoding UTF8
}

$root = [IO.Path]::GetFullPath($RuntimeRoot)
Assert-True ([IO.Path]::IsPathRooted($root)) "runtime_root_must_be_absolute"
Assert-True ($root -ne [IO.Path]::GetPathRoot($root)) "runtime_root_cannot_be_volume_root"
if ($FixtureMode) { Assert-FixtureRoot $root }
$confirm = switch ($Operation) {
  "Install" { [bool]$ConfirmInstall }; "Upgrade" { [bool]$ConfirmUpgrade };
  "Rollback" { [bool]$ConfirmRollback }; "Uninstall" { [bool]$ConfirmUninstall }; default { $false }
}
if ($Operation -ne "Status") { Assert-True ($DryRun -xor $confirm) "exactly_one_dry_run_or_matching_confirmation_required" }

if ($DryRun) {
  if ($Operation -in @("Install", "Upgrade")) {
    Assert-True ($ArtifactPath -and $ManifestPath -and $EnvPath -and $NodeConfigPath) "artifact_manifest_configs_required"
    & $verifier -ArtifactPath $ArtifactPath -ManifestPath $ManifestPath -AllowFixtureRuntime:$FixtureMode | Out-Null
    Get-CombinedConfigIdentity $EnvPath $NodeConfigPath | Out-Null
  }
  [ordered]@{ ok = $true; operation = $Operation; dry_run = $true; fixture_mode = [bool]$FixtureMode; mutation_performed = $false; service_registered = $false; production_contact = $false; lax_runtime_touched = $false } | ConvertTo-Json -Compress
  exit 0
}
if (-not $FixtureMode -and $Operation -ne "Status") {
  Assert-True ($AuthorizationId -match "^[A-Za-z0-9._-]{8,128}$") "production_authorization_id_required"
  Assert-True (Test-Administrator) "administrator_required_for_service_mutation"
  Assert-True ($ServiceWrapperPath -and (Test-Path -LiteralPath $ServiceWrapperPath -PathType Leaf)) "service_wrapper_required"
  Assert-True ((Get-Sha256 $ServiceWrapperPath) -eq [string]$trust.service_wrapper.sha256) "service_wrapper_sha256_mismatch"
}
if ($Operation -eq "Status") {
  $releaseTarget = Get-ActiveTarget (Join-Path $root "active\agent")
  $configTarget = Get-ActiveTarget (Join-Path $root "config\agent\active")
  $manifest = if ($releaseTarget -and (Test-Path -LiteralPath (Join-Path $releaseTarget "release-manifest.json"))) { Get-Content -Raw -LiteralPath (Join-Path $releaseTarget "release-manifest.json") | ConvertFrom-Json } else { $null }
  $spoolCount = 0
  if ($configTarget) {
    $spoolPath = Get-EnvValue (Join-Path $configTarget "agent.env") "SPOOL_DIR"
    if ($spoolPath -and (Test-Path -LiteralPath $spoolPath)) { $spoolCount = @(Get-ChildItem -LiteralPath $spoolPath -File -ErrorAction SilentlyContinue).Count }
  }
  [ordered]@{
    ok = $true; installed = [bool]($releaseTarget -and $configTarget)
    active_release_id = if ($releaseTarget) { Split-Path -Leaf $releaseTarget } else { $null }
    active_config_id = if ($configTarget) { Split-Path -Leaf $configTarget } else { $null }
    source_commit = if ($manifest) { [string]$manifest.source_commit } else { $null }
    artifact_sha256 = if ($manifest) { [string]$manifest.artifact_sha256 } else { $null }
    runtime_version = if ($manifest) { [string]$manifest.runtime_version } else { $null }
    pending_spool_count = $spoolCount; service_identity = $serviceName; secret_values_printed = $false
  } | ConvertTo-Json -Compress
  exit 0
}

if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
$lockPath = Join-Path $root ".agent-runtime.lock"
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  if ($FixtureMode) {
    $marker = Join-Path $root ".mg44-fixture-owner.json"
    if (-not (Test-Path -LiteralPath $marker)) { [ordered]@{ schema_version = "jerry.fixture-owner.v1"; component = $component } | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8 }
  }
  if ($Operation -in @("Install", "Upgrade")) {
    Assert-True ($ArtifactPath -and $ManifestPath -and $EnvPath -and $NodeConfigPath) "artifact_manifest_configs_required"
    & $verifier -ArtifactPath $ArtifactPath -ManifestPath $ManifestPath -AllowFixtureRuntime:$FixtureMode | Out-Null
    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    $configId = Get-CombinedConfigIdentity $EnvPath $NodeConfigPath
    $releaseId = "$($manifest.source_commit)-$(([string]$manifest.artifact_sha256).Substring(0, 16))"
    $releaseDir = Join-Path $root "releases\agent\$releaseId"
    $configDir = Join-Path $root "config\agent\revisions\$configId"
    if (-not (Test-Path -LiteralPath $releaseDir)) {
      $stage = "$releaseDir.staging"
      if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
      New-Item -ItemType Directory -Force -Path $stage | Out-Null
      Expand-Archive -LiteralPath $ArtifactPath -DestinationPath $stage
      & $verifier -ArtifactPath $ArtifactPath -ManifestPath $ManifestPath -ExtractedRoot $stage -AllowFixtureRuntime:$FixtureMode | Out-Null
      Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $stage "release-manifest.json")
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $releaseDir) | Out-Null
      Move-Item -LiteralPath $stage -Destination $releaseDir
    }
    if (-not (Test-Path -LiteralPath $configDir)) {
      New-Item -ItemType Directory -Force -Path $configDir | Out-Null
      Copy-Item -LiteralPath $EnvPath -Destination (Join-Path $configDir "agent.env")
      Copy-Item -LiteralPath $NodeConfigPath -Destination (Join-Path $configDir "node.json")
    }
    $activeRelease = Join-Path $root "active\agent"; $activeConfig = Join-Path $root "config\agent\active"
    $previousRelease = Get-ActiveTarget $activeRelease; $previousConfig = Get-ActiveTarget $activeConfig
    if ($Operation -eq "Install") { Assert-True (-not $previousRelease) "agent_already_installed" } else { Assert-True ([bool]$previousRelease) "agent_upgrade_requires_existing_release" }
    if (-not $FixtureMode) {
      $serviceDir = Join-Path $root "services\agent"; New-Item -ItemType Directory -Force -Path $serviceDir | Out-Null
      $serviceExe = Join-Path $serviceDir "agent-service.exe"; Copy-Item -LiteralPath $ServiceWrapperPath -Destination $serviceExe -Force
      $template = if ($ServiceTemplatePath) { $ServiceTemplatePath } else { $defaultTemplate }
      $xml = Get-Content -Raw -LiteralPath $template
      $xml = $xml.Replace("__ACTIVE_ROOT__", $activeRelease).Replace("__ENV_PATH__", (Join-Path $activeConfig "agent.env")).Replace("__NODE_CONFIG_PATH__", (Join-Path $activeConfig "node.json"))
      Set-Content -LiteralPath (Join-Path $serviceDir "agent-service.xml") -Value $xml -Encoding UTF8
      if ($Operation -eq "Upgrade") { Invoke-ServiceCommand $serviceExe "stop" }
    }
    Set-ActiveJunction $activeRelease $releaseDir; Set-ActiveJunction $activeConfig $configDir
    if (-not $FixtureMode) {
      $serviceExe = Join-Path $root "services\agent\agent-service.exe"
      if ($Operation -eq "Install") { Invoke-ServiceCommand $serviceExe "install" }
      Invoke-ServiceCommand $serviceExe "start"
    }
    if (-not (Test-AgentHealth $activeRelease $activeConfig)) {
      if (-not $FixtureMode) { Invoke-ServiceCommand (Join-Path $root "services\agent\agent-service.exe") "stop" }
      if ($previousRelease -and $previousConfig) {
        Set-ActiveJunction $activeRelease $previousRelease; Set-ActiveJunction $activeConfig $previousConfig
        if (-not $FixtureMode) { Invoke-ServiceCommand (Join-Path $root "services\agent\agent-service.exe") "start" }
      }
      throw "agent_activation_health_failed_rolled_back"
    }
    Write-Transaction @{
      operation = $Operation; previous_release = if ($previousRelease) { Split-Path -Leaf $previousRelease } else { $null }
      previous_config = if ($previousConfig) { Split-Path -Leaf $previousConfig } else { $null }
      active_release = $releaseId; active_config = $configId; artifact_sha256 = [string]$manifest.artifact_sha256
      state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true
    }
    [ordered]@{ ok = $true; operation = $Operation; active_release = $releaseId; active_config = $configId; health = "pass"; fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
    exit 0
  }
  if ($Operation -eq "Rollback") {
    $transactionPath = Join-Path $root "transactions\agent-current.json"
    Assert-True (Test-Path -LiteralPath $transactionPath) "rollback_transaction_missing"
    $transaction = Get-Content -Raw -LiteralPath $transactionPath | ConvertFrom-Json
    Assert-True ([bool]$transaction.previous_release -and [bool]$transaction.previous_config) "rollback_previous_slot_missing"
    $releaseDir = Join-Path $root "releases\agent\$($transaction.previous_release)"; $configDir = Join-Path $root "config\agent\revisions\$($transaction.previous_config)"
    Assert-True (Test-Path -LiteralPath $releaseDir) "rollback_release_missing"; Assert-True (Test-Path -LiteralPath $configDir) "rollback_config_missing"
    $activeRelease = Join-Path $root "active\agent"; $activeConfig = Join-Path $root "config\agent\active"
    $currentRelease = Get-ActiveTarget $activeRelease; $currentConfig = Get-ActiveTarget $activeConfig
    if (-not $FixtureMode) { Invoke-ServiceCommand (Join-Path $root "services\agent\agent-service.exe") "stop" }
    Set-ActiveJunction $activeRelease $releaseDir; Set-ActiveJunction $activeConfig $configDir
    if (-not $FixtureMode) { Invoke-ServiceCommand (Join-Path $root "services\agent\agent-service.exe") "start" }
    Assert-True (Test-AgentHealth $activeRelease $activeConfig) "rollback_health_failed"
    Write-Transaction @{
      operation = "Rollback"; previous_release = if ($currentRelease) { Split-Path -Leaf $currentRelease } else { $null }
      previous_config = if ($currentConfig) { Split-Path -Leaf $currentConfig } else { $null }
      active_release = Split-Path -Leaf $releaseDir; active_config = Split-Path -Leaf $configDir
      state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true
    }
    [ordered]@{ ok = $true; operation = "Rollback"; active_release = (Split-Path -Leaf $releaseDir); no_rebuild = $true; state_preserved = $true; spool_preserved = $true; secret_file_preserved = $true; fixture_mode = [bool]$FixtureMode } | ConvertTo-Json -Compress
    exit 0
  }
  if ($Operation -eq "Uninstall") {
    if (-not $FixtureMode) {
      $serviceExe = Join-Path $root "services\agent\agent-service.exe"
      if (Test-Path -LiteralPath $serviceExe) { try { Invoke-ServiceCommand $serviceExe "stop" } catch { }; Invoke-ServiceCommand $serviceExe "uninstall" }
      $activePath = Join-Path $root "active\agent"; if (Test-Path -LiteralPath $activePath) { Remove-Junction $activePath }
      $servicePath = Join-Path $root "services\agent"; if (Test-Path -LiteralPath $servicePath) { Remove-Item -LiteralPath $servicePath -Recurse -Force }
    } else {
      $marker = Join-Path $root ".mg44-fixture-owner.json"; Assert-True (Test-Path -LiteralPath $marker) "fixture_owner_marker_missing"
      foreach ($junction in @((Join-Path $root "active\agent"), (Join-Path $root "config\agent\active"))) { if (Test-Path -LiteralPath $junction) { Remove-Junction $junction } }
      $lock.Dispose(); $lock = $null; Remove-Item -LiteralPath $root -Recurse -Force
    }
    [ordered]@{ ok = $true; operation = "Uninstall"; service_removed = $true; persistent_data_preserved = (-not $FixtureMode); fixture_mode = [bool]$FixtureMode; lax_runtime_touched = $false } | ConvertTo-Json -Compress
    exit 0
  }
} finally { if ($null -ne $lock) { $lock.Dispose() } }
