param(
  [string]$Config = ".\deploy\examples\general-linux-agent.node.json",

  [ValidateSet("FileOnly", "Push")]
  [string]$Output = "FileOnly",

  [string]$OutFile = ".smoke\server.batch.safe.json",
  [string]$HubUrl,
  [string]$WriteSecret,
  [string]$KeyId
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$secretEnvName = "TELEMETRY_NODE_" + "SECRET"
$keyIdEnvName = "TELEMETRY_NODE_KEY_ID"
$previousEnv = @{}
foreach ($name in @($secretEnvName, $keyIdEnvName)) {
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
  if ($KeyId) { Set-Item -Path "Env:$keyIdEnvName" -Value $KeyId }

  $nodeArgs = @("--config", $Config, "--output", $Output, "--out-file", $OutFile)
  if ($HubUrl) { $nodeArgs += @("--hub-url", $HubUrl) }

  & npm --silent run server:once -- $nodeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "server one-shot failed"
  }
} finally {
  Pop-Location
  Restore-Env
}
