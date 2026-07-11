param(
  [Parameter(Mandatory = $true)][string]$ArtifactPath,
  [Parameter(Mandatory = $true)][string]$ManifestPath,
  [string]$ExtractedRoot,
  [string]$ExpectedSourceCommit,
  [switch]$AllowFixtureRuntime
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
function Get-StreamSha256 {
  param([System.IO.Stream]$Stream)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace("-", "").ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function Normalize-RelativePath {
  param([string]$Path)
  $normalized = $Path.Replace("\", "/").TrimStart("/")
  Assert-True (-not [IO.Path]::IsPathRooted($Path)) "manifest_path_must_be_relative"
  Assert-True (-not ($normalized -split "/" | Where-Object { $_ -eq ".." })) "manifest_path_traversal"
  return $normalized
}
function Get-SafeRelativePath {
  param([string]$Root, [string]$Path)
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
  $pathFull = [IO.Path]::GetFullPath($Path)
  Assert-True ($pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) "path_outside_root"
  return $pathFull.Substring($rootFull.Length)
}

$artifact = (Resolve-Path -LiteralPath $ArtifactPath).Path
$manifestFile = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifestText = [IO.File]::ReadAllText($manifestFile)
$manifest = $manifestText | ConvertFrom-Json
$required = @(
  "schema_version", "component", "source_repository", "source_commit",
  "artifact_filename", "artifact_sha256", "artifact_size_bytes",
  "runtime_version", "build_tool_version", "artifact_file_list_or_digest",
  "required_config_key_names", "default_activation_state", "build_timestamp"
)
foreach ($name in $required) { Assert-True ($manifest.PSObject.Properties.Name -contains $name) "manifest_missing_$name" }

Assert-True ($manifest.schema_version -eq "jerry.workstation.release.v1") "manifest_schema_invalid"
Assert-True ($manifest.component -eq "jerry-telemetry-agent") "manifest_component_invalid"
Assert-True ($manifest.source_repository -eq "JerrySkywalker/jerry-telemetry-agent") "manifest_repository_invalid"
Assert-True ([string]$manifest.source_commit -match "^[0-9a-f]{40}$") "manifest_source_commit_invalid"
if ($ExpectedSourceCommit) { Assert-True ($manifest.source_commit -eq $ExpectedSourceCommit.ToLowerInvariant()) "manifest_source_commit_mismatch" }
Assert-True ([IO.Path]::GetFileName([string]$manifest.artifact_filename) -eq [string]$manifest.artifact_filename) "manifest_artifact_filename_invalid"
Assert-True ([IO.Path]::GetFileName($artifact) -eq [string]$manifest.artifact_filename) "manifest_artifact_filename_mismatch"
Assert-True ([string]$manifest.artifact_sha256 -match "^[0-9a-f]{64}$") "manifest_artifact_sha256_invalid"
Assert-True ((Get-Sha256 $artifact) -eq [string]$manifest.artifact_sha256) "artifact_sha256_mismatch"
Assert-True ((Get-Item -LiteralPath $artifact).Length -eq [int64]$manifest.artifact_size_bytes) "artifact_size_mismatch"
Assert-True ([string]$manifest.runtime_version -match "^22\.[0-9]+\.[0-9]+$") "runtime_version_must_be_node_22"
Assert-True ($manifest.artifact_file_list_or_digest.algorithm -eq "sha256") "manifest_file_algorithm_invalid"
Assert-True (@($manifest.required_config_key_names).Count -gt 0) "manifest_config_keys_missing"
foreach ($key in @($manifest.required_config_key_names)) { Assert-True ([string]$key -match "^[A-Z][A-Z0-9_]{1,127}$") "manifest_config_key_invalid" }
Assert-True ($manifest.default_activation_state.message_gateway_readiness_collector_enabled -eq $false) "manifest_collector_default_must_be_disabled"
Assert-True ($manifest.default_activation_state.output_mode -eq "file") "manifest_output_mode_default_must_be_file"
if ($manifest.PSObject.Properties.Name -contains "fixture_runtime" -and $manifest.fixture_runtime -eq $true) {
  Assert-True ([bool]$AllowFixtureRuntime) "fixture_runtime_rejected"
}
Assert-True (-not ($manifestText -match "(?i)-----BEGIN .*PRIVATE KEY-----|Bearer\s+|gh[pousr]_|sk-[A-Za-z0-9]{10,}")) "manifest_forbidden_secret_marker"
Assert-True (-not ($manifestText -match "(?i)https?://|[A-Za-z]:\\")) "manifest_machine_or_endpoint_value_forbidden"

$expectedFiles = @{}
foreach ($item in @($manifest.artifact_file_list_or_digest.files)) {
  $relative = Normalize-RelativePath ([string]$item.path)
  Assert-True (-not $expectedFiles.ContainsKey($relative)) "manifest_duplicate_file"
  Assert-True ([string]$item.sha256 -match "^[0-9a-f]{64}$") "manifest_file_sha256_invalid"
  $expectedFiles[$relative] = $item
}
Assert-True ($expectedFiles.Count -gt 0) "manifest_file_inventory_empty"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archiveFiles = @{}
$zip = [IO.Compression.ZipFile]::OpenRead($artifact)
try {
  foreach ($entry in $zip.Entries) {
    if (-not $entry.Name) { continue }
    $relative = Normalize-RelativePath $entry.FullName
    Assert-True (-not $archiveFiles.ContainsKey($relative)) "artifact_duplicate_file"
    $stream = $entry.Open()
    try { $archiveFiles[$relative] = [ordered]@{ size_bytes = [int64]$entry.Length; sha256 = Get-StreamSha256 $stream } }
    finally { $stream.Dispose() }
  }
} finally { $zip.Dispose() }
Assert-True ($archiveFiles.Count -eq $expectedFiles.Count) "artifact_file_count_mismatch"
foreach ($relative in $expectedFiles.Keys) {
  Assert-True ($archiveFiles.ContainsKey($relative)) "artifact_file_missing"
  Assert-True ($archiveFiles[$relative].sha256 -eq [string]$expectedFiles[$relative].sha256) "artifact_file_sha256_mismatch"
  Assert-True ($archiveFiles[$relative].size_bytes -eq [int64]$expectedFiles[$relative].size_bytes) "artifact_file_size_mismatch"
}

if ($ExtractedRoot) {
  $root = (Resolve-Path -LiteralPath $ExtractedRoot).Path
  $actual = @{}
  Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
    $relative = Normalize-RelativePath (Get-SafeRelativePath $root $_.FullName)
    if ($relative -ne "release-manifest.json") { $actual[$relative] = [ordered]@{ size_bytes = $_.Length; sha256 = Get-Sha256 $_.FullName } }
  }
  Assert-True ($actual.Count -eq $expectedFiles.Count) "extracted_file_count_mismatch"
  foreach ($relative in $expectedFiles.Keys) {
    Assert-True ($actual.ContainsKey($relative)) "extracted_file_missing"
    Assert-True ($actual[$relative].sha256 -eq [string]$expectedFiles[$relative].sha256) "extracted_file_sha256_mismatch"
  }
}

[ordered]@{
  ok = $true
  component = [string]$manifest.component
  source_commit = [string]$manifest.source_commit
  artifact_sha256 = [string]$manifest.artifact_sha256
  runtime_version = [string]$manifest.runtime_version
  file_count = $expectedFiles.Count
  secret_values_printed = $false
} | ConvertTo-Json -Compress
