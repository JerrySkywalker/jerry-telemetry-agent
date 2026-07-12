param(
  [Parameter(Mandatory = $true)][string]$EnvPath,
  [Parameter(Mandatory = $true)][string]$NodeConfigPath,
  [Parameter(Mandatory = $true)][string]$RuntimeRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
function Read-SafeEnvMetadata {
  param([string]$Path)
  $result = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    $index = $line.IndexOf("="); if ($index -lt 1) { continue }
    $name = $line.Substring(0, $index).Trim()
    Assert-True ($name -ne "TELEMETRY_NODE_SECRET") "direct_signing_secret_forbidden_in_workstation_mode"
    if ($name -in @("TELEMETRY_NODE_SECRET_FILE", "TELEMETRY_NODE_KEY_ID")) { $result[$name] = $line.Substring($index + 1).Trim() }
  }
  return $result
}
function Assert-PlainLocalFile {
  param([string]$Path)
  Assert-True ([IO.Path]::IsPathRooted($Path) -and -not ($Path -match "^(?i)\\\\|\\\\\?\\|\\\\\.\\|[a-z][a-z0-9+.-]*://")) "anchor_path_local_absolute_required"
  Assert-True (-not (@($Path -split "[\\/]" | Where-Object { $_ -eq ".." }).Count)) "anchor_path_traversal_forbidden"
  $full = [IO.Path]::GetFullPath($Path); Assert-True (Test-Path -LiteralPath $full -PathType Leaf) "anchor_path_missing"
  $item = Get-Item -LiteralPath $full -Force
  Assert-True (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "anchor_path_reparse_forbidden"
  if ($item.PSObject.Properties.Name -contains "LinkType") { Assert-True ([string]$item.LinkType -notin @("SymbolicLink", "Junction", "HardLink")) "anchor_path_link_forbidden" }
  return $full
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$trust = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "deploy\workstation\trusted-runtime.json") | ConvertFrom-Json
$envFile = Assert-PlainLocalFile $EnvPath; $nodeFile = Assert-PlainLocalFile $NodeConfigPath
$metadata = Read-SafeEnvMetadata $envFile
$secretFile = Assert-PlainLocalFile ([string]$metadata.TELEMETRY_NODE_SECRET_FILE)
$runtime = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd("\") + "\"
Assert-True (-not $secretFile.StartsWith($runtime, [StringComparison]::OrdinalIgnoreCase)) "secret_reference_inside_runtime_root"
$node = Get-Content -Raw -LiteralPath $nodeFile | ConvertFrom-Json
$nodeId = [string]$node.node_id; $keyId = [string]$metadata.TELEMETRY_NODE_KEY_ID
Assert-True ($nodeId -match "^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$" -and $keyId -match "^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$") "identity_metadata_invalid"
Assert-True (-not ($nodeId -match "(?i)lax") -and -not ($keyId -match "(?i)lax")) "lax_identity_forbidden"
$secretBinding = Get-TextSha256 ("jerry.workstation.secret-reference.v1|" + $secretFile.ToLowerInvariant() + "|" + [string]$trust.service_account.binding_sha256)
$configBinding = Get-TextSha256 ((Get-Sha256 $envFile) + (Get-Sha256 $nodeFile))
$agentBinding = Get-TextSha256 ("jerry.workstation.agent-identity.v1|$nodeId|$keyId|$secretBinding")
[ordered]@{
  schema_version = "jerry.workstation.binding-anchors.v1"
  agent_identity_binding_sha256 = $agentBinding
  config_binding_sha256 = $configBinding
  secret_reference_binding_sha256 = $secretBinding
  secret_reference_present = $true
  secret_value_accessed = $false
  private_path_printed = $false
} | ConvertTo-Json -Compress
