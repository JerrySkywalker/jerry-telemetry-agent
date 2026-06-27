param(
  [string]$EnvPath,
  [string]$NodeConfigPath,

  [ValidateSet("Local", "Server", "LaxCodex")]
  [string]$Mode = "Server",

  [switch]$StrictProduction,
  [switch]$NoNetwork
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  $nodeArgs = @("--mode", $Mode)
  if ($EnvPath) { $nodeArgs += @("--env-path", $EnvPath) }
  if ($NodeConfigPath) { $nodeArgs += @("--node-config-path", $NodeConfigPath) }
  if ($StrictProduction) { $nodeArgs += "--strict-production" }
  if ($NoNetwork) { $nodeArgs += "--no-network" }

  & npm --silent run doctor:agent-config -- $nodeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "agent config doctor failed"
  }
} finally {
  Pop-Location
}
