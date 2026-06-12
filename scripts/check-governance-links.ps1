$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$required = @(
  "docs/governance/JERRY_CONFIG_GOVERNANCE_POINTER.md",
  "docs/ops/lax-agent-production-deploy.md",
  "docs/ops/lax-agent-diagnostics.md",
  "docs/incidents/2026-06-12-mg020-rescue.md"
)

$ok = $true
foreach ($path in $required) {
  $exists = Test-Path -LiteralPath $path -PathType Leaf
  Write-Output "$(($path -replace '[^A-Za-z0-9]+','_').Trim('_'))_present=$($exists.ToString().ToLowerInvariant())"
  if (-not $exists) { $ok = $false }
}

$readme = Get-Content -LiteralPath "README.md" -Raw
$linked = $readme.Contains("docs/governance/JERRY_CONFIG_GOVERNANCE_POINTER.md") -and
  $readme.Contains("docs/ops/lax-agent-production-deploy.md")
Write-Output "readme_governance_links_present=$($linked.ToString().ToLowerInvariant())"
if (-not $linked) { $ok = $false }

if (-not $ok) {
  exit 1
}
