param(
  [ValidateSet("Once", "Daemon")]
  [string]$Mode = "Once",

  [string]$HubRepoPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")) "jerry-telemetry-hub"),
  [string]$HubHost = "127.0.0.1",
  [int]$HubPort = 3300,
  [string]$NodeId = "local-e2e-node-01",
  [string]$SmokeRoot = ".smoke\local-hub-agent-e2e"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

if (-not (Test-Path -LiteralPath (Join-Path $HubRepoPath "package.json") -PathType Leaf)) {
  Write-Host "SKIP local_hub_agent_e2e reason=sibling_hub_repo_missing"
  exit 0
}

Push-Location $repoRoot
try {
  & npm --silent run smoke:local-hub-agent-e2e -- `
    --mode $Mode `
    --hub-repo-path $HubRepoPath `
    --hub-host $HubHost `
    --hub-port $HubPort `
    --node-id $NodeId `
    --smoke-root $SmokeRoot
  if ($LASTEXITCODE -ne 0) {
    throw "local Hub agent E2E failed"
  }
} finally {
  Pop-Location
}
