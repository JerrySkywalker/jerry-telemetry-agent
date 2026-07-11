param(
  [Parameter(Mandatory = $true)][string]$ReleaseRoot,
  [Parameter(Mandatory = $true)][string]$EnvPath,
  [Parameter(Mandatory = $true)][string]$NodeConfigPath,
  [switch]$ValidateOnly,
  [switch]$AllowFixtureRuntime,
  [switch]$RequireSafeDefaults
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True { param([bool]$Condition, [string]$Code); if (-not $Condition) { throw $Code } }
function Get-Sha256 {
  param([string]$Path)
  $stream = [IO.File]::OpenRead($Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose(); $stream.Dispose() }
}
function Read-ProtectedEnvFile {
  param([string]$Path)
  $result = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
    $index = $trimmed.IndexOf("=")
    Assert-True ($index -gt 0) "runtime_config_line_invalid"
    $name = $trimmed.Substring(0, $index).Trim()
    $value = $trimmed.Substring($index + 1).Trim()
    Assert-True ($name -match "^[A-Z][A-Z0-9_]{1,127}$") "runtime_config_key_invalid"
    Assert-True (-not $result.ContainsKey($name)) "runtime_config_key_duplicate"
    Assert-True (-not ($value -match "^<.*>$")) "runtime_config_placeholder_rejected"
    $result[$name] = $value
  }
  return $result
}
function Assert-OutsideRelease {
  param([string]$Path, [string]$Root, [string]$Code)
  Assert-True ([IO.Path]::IsPathRooted($Path)) $Code
  $full = [IO.Path]::GetFullPath($Path)
  Assert-True (-not $full.StartsWith("\\")) $Code
  $release = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
  Assert-True (-not $full.StartsWith($release, [StringComparison]::OrdinalIgnoreCase)) $Code
}

$root = (Resolve-Path -LiteralPath $ReleaseRoot).Path
$envFile = (Resolve-Path -LiteralPath $EnvPath).Path
$nodeConfigFile = (Resolve-Path -LiteralPath $NodeConfigPath).Path
$manifestPath = Join-Path $root "release-manifest.json"
Assert-True (Test-Path -LiteralPath $manifestPath) "release_manifest_missing"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
Assert-True ($manifest.schema_version -eq "jerry.workstation.release.v1") "release_manifest_schema_invalid"
Assert-True ($manifest.component -eq "jerry-telemetry-agent") "release_manifest_component_invalid"
$fixtureRuntime = $manifest.fixture_runtime -eq $true
Assert-True (-not $fixtureRuntime -or ($ValidateOnly -and $AllowFixtureRuntime)) "fixture_release_cannot_start_as_service"
Assert-True ($manifest.platform -eq "win32" -and $manifest.architecture -eq "x64") "release_platform_invalid"
$fixedEntrypoint = "app/dist/src/server-agent-daemon.js"
Assert-True ([string]$manifest.entrypoint -eq $fixedEntrypoint) "release_entrypoint_invalid"
$inventory = @{}
foreach ($item in @($manifest.artifact_file_list_or_digest.files)) {
  $relative = ([string]$item.path).Replace("\", "/")
  Assert-True (-not [IO.Path]::IsPathRooted($relative)) "release_inventory_path_invalid"
  Assert-True (-not ($relative -split "/" | Where-Object { $_ -eq ".." })) "release_inventory_path_traversal"
  Assert-True (-not $inventory.ContainsKey($relative)) "release_inventory_path_duplicate"
  $file = Join-Path $root $relative
  Assert-True (Test-Path -LiteralPath $file -PathType Leaf) "release_inventory_file_missing"
  Assert-True ((Get-Sha256 $file) -eq [string]$item.sha256) "release_inventory_hash_mismatch"
  Assert-True ((Get-Item -LiteralPath $file).Length -eq [int64]$item.size_bytes) "release_inventory_size_mismatch"
  $inventory[$relative] = $true
}
Assert-True ($inventory.ContainsKey($fixedEntrypoint)) "release_entrypoint_not_in_inventory"
Assert-True ($inventory.ContainsKey("runtime/node.exe")) "release_node_not_in_inventory"

$runtime = Join-Path $root "runtime\node.exe"
$entrypoint = Join-Path $root $fixedEntrypoint
$rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd("\") + "\"
Assert-True ([IO.Path]::GetFullPath($entrypoint).StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) "release_entrypoint_outside_root"
Assert-True (Test-Path -LiteralPath $runtime -PathType Leaf) "release_node_missing"
Assert-True (Test-Path -LiteralPath $entrypoint -PathType Leaf) "release_entrypoint_missing"
if (-not $fixtureRuntime) {
  $nodeVersion = (& $runtime --version).Trim()
  Assert-True ($nodeVersion -eq ("v" + [string]$manifest.runtime_version)) "release_node_version_mismatch"
  Assert-True ($nodeVersion.StartsWith("v22.")) "release_node_major_must_be_22"
}

$values = Read-ProtectedEnvFile $envFile
$values["TELEMETRY_NODE_CONFIG_PATH"] = $nodeConfigFile
foreach ($name in @($manifest.required_config_key_names)) { Assert-True ($values.ContainsKey([string]$name)) "runtime_required_config_key_missing" }
Assert-True ($values.ContainsKey("TELEMETRY_OUTPUT_MODE")) "runtime_output_mode_missing"
Assert-True (@("file", "file,http") -contains [string]$values["TELEMETRY_OUTPUT_MODE"]) "runtime_output_mode_invalid"
if ($RequireSafeDefaults) { Assert-True ([string]$values["TELEMETRY_OUTPUT_MODE"] -eq "file") "runtime_output_must_default_file_only" }
Assert-True ($values.ContainsKey("HEALTH_HOST") -and @("127.0.0.1", "::1", "localhost") -contains [string]$values["HEALTH_HOST"]) "runtime_health_host_must_be_loopback"
Assert-True ($values.ContainsKey("HEALTH_PORT") -and [string]$values["HEALTH_PORT"] -match "^[0-9]{1,5}$" -and [int]$values["HEALTH_PORT"] -ge 1 -and [int]$values["HEALTH_PORT"] -le 65535) "runtime_health_port_invalid"
Assert-True ($values.ContainsKey("HEALTH_SERVER_ENABLED") -and [string]$values["HEALTH_SERVER_ENABLED"] -eq "true") "runtime_health_server_required"
Assert-True ($values.ContainsKey("TELEMETRY_HUB_REQUEST_TIMEOUT_MS") -and [int]$values["TELEMETRY_HUB_REQUEST_TIMEOUT_MS"] -ge 1 -and [int]$values["TELEMETRY_HUB_REQUEST_TIMEOUT_MS"] -le 30000) "runtime_upload_timeout_invalid"
Assert-True ($values.ContainsKey("TELEMETRY_NODE_SECRET_FILE")) "runtime_secret_file_reference_missing"
Assert-OutsideRelease ([string]$values["TELEMETRY_NODE_SECRET_FILE"]) $root "runtime_secret_file_must_be_external_absolute"
Assert-True (Test-Path -LiteralPath ([string]$values["TELEMETRY_NODE_SECRET_FILE"]) -PathType Leaf) "runtime_secret_file_missing"
$secretLines = @(Get-Content -LiteralPath ([string]$values["TELEMETRY_NODE_SECRET_FILE"]) | Where-Object { $_.Trim() })
Assert-True ($secretLines.Count -eq 1) "runtime_secret_file_must_contain_one_line"
foreach ($name in @("STATE_PATH", "SPOOL_DIR", "TELEMETRY_SERVER_BATCH_LATEST_FILE", "TELEMETRY_BATCH_OUTPUT_FILE")) {
  Assert-True ($values.ContainsKey($name)) "runtime_state_path_missing"
  Assert-OutsideRelease ([string]$values[$name]) $root "runtime_state_path_must_be_external_absolute"
}

$nodeConfig = Get-Content -Raw -LiteralPath $nodeConfigFile | ConvertFrom-Json
Assert-True ([string]$nodeConfig.node_id -and [string]$nodeConfig.node_id -ne "us-lax-pro-01") "runtime_node_identity_must_not_reuse_lax"
Assert-True ($nodeConfig.role -eq "message-gateway" -and $nodeConfig.provider -eq "local") "runtime_node_role_invalid"
$collector = @($nodeConfig.collectors | Where-Object { $_.name -eq "message-gateway-readiness" })
Assert-True ($collector.Count -eq 1) "runtime_gateway_collector_missing_or_duplicate"
if ($RequireSafeDefaults) { Assert-True ($collector[0].enabled -eq $false) "runtime_gateway_collector_must_default_disabled" }
$target = [Uri]$collector[0].target.url
Assert-True ($target.Scheme -eq "http" -and -not $target.UserInfo -and -not $target.Query -and -not $target.Fragment) "runtime_gateway_target_invalid"
Assert-True (@("127.0.0.1", "localhost", "[::1]", "::1") -contains $target.Host) "runtime_gateway_target_must_be_loopback"
Assert-True ($target.AbsolutePath -eq "/v1/telemetry/readiness") "runtime_gateway_target_path_invalid"
Assert-True ([int]$collector[0].target.timeout_ms -ge 1 -and [int]$collector[0].target.timeout_ms -le 2000) "runtime_gateway_timeout_invalid"

if ($ValidateOnly) {
  [ordered]@{
    ok = $true; component = "jerry-telemetry-agent"; source_commit = [string]$manifest.source_commit
    config_valid = $true; loopback_only = $true; collector_default_disabled = $true
    secret_reference_valid = $true; secret_values_printed = $false
  } | ConvertTo-Json -Compress
  return
}

$previous = @{}
try {
  foreach ($name in $values.Keys) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    [Environment]::SetEnvironmentVariable($name, [string]$values[$name], "Process")
  }
  Push-Location (Join-Path $root "app")
  try {
    & $runtime $entrypoint
    exit $LASTEXITCODE
  } finally { Pop-Location }
} finally {
  foreach ($name in $values.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process") }
}
