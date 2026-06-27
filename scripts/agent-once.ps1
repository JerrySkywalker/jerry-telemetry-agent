param(
  [ValidateSet("Fixture", "LocalWindows")]
  [string]$Mode = "Fixture",

  [ValidateSet("FileOnly", "Push")]
  [string]$Output = "FileOnly",

  [string]$NodeId = "local-win-dev-01",
  [string]$Region = "local",
  [string]$Role = "dev-node",
  [string]$Provider = "local",
  [string]$HubUrl,
  [string]$WriteSecret,
  [string]$ReadToken,
  [string]$OutFile = ".smoke\telemetry-batch.safe.json",
  [switch]$SkipReadback,
  [string]$KeyId,
  [string]$CustomJsonFile,
  [string]$ServiceHealthFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$secretEnvName = "TELEMETRY_NODE_" + "SECRET"
$readTokenEnvName = "TELEMETRY_READ_" + "TOKEN"
$keyIdEnvName = "TELEMETRY_NODE_KEY_ID"
$previousEnv = @{}
foreach ($name in @($secretEnvName, $readTokenEnvName, $keyIdEnvName)) {
  $previousEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}

function Restore-Env {
  foreach ($key in $previousEnv.Keys) {
    if ($null -eq $previousEnv[$key]) {
      Remove-Item -Path "Env:$key" -ErrorAction SilentlyContinue
    } else {
      Set-Item -Path "Env:$key" -Value $previousEnv[$key]
    }
  }
}

Push-Location $repoRoot
try {
  if ($WriteSecret) { Set-Item -Path "Env:$secretEnvName" -Value $WriteSecret }
  if ($ReadToken) { Set-Item -Path "Env:$readTokenEnvName" -Value $ReadToken }
  if ($KeyId) { Set-Item -Path "Env:$keyIdEnvName" -Value $KeyId }

  $nodeArgs = @(
    "--mode", $Mode,
    "--output", $Output,
    "--node-id", $NodeId,
    "--region", $Region,
    "--role", $Role,
    "--provider", $Provider,
    "--out-file", $OutFile
  )
  if ($HubUrl) { $nodeArgs += @("--hub-url", $HubUrl) }
  if ($SkipReadback) { $nodeArgs += "--skip-readback" }
  if ($CustomJsonFile) { $nodeArgs += @("--custom-json-file", $CustomJsonFile) }
  if ($ServiceHealthFile) { $nodeArgs += @("--service-health-file", $ServiceHealthFile) }

  & npm --silent run agent:once -- $nodeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "agent one-shot failed"
  }
} finally {
  Pop-Location
  Restore-Env
}
