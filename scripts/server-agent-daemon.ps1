param(
  [string]$Config = ".\deploy\examples\general-linux-agent.node.json",

  [ValidateSet("FileOnly", "Push")]
  [string]$Output = "FileOnly",

  [string]$OutFile = ".smoke\server-daemon\server.batch.safe.json",
  [string]$LatestFile = ".smoke\server-daemon\server.batch.latest.safe.json",
  [string]$StatePath = ".smoke\server-daemon\agent-state.json",
  [string]$SpoolDir = ".smoke\server-daemon\spool",
  [int]$IntervalSeconds = 60,
  [int]$MaxIterations = 0,
  [string]$HubUrl,
  [string]$HubBatchUrl,
  [string]$WriteSecret,
  [string]$KeyId,
  [int]$SpoolMaxFiles = 100,
  [int]$SpoolMaxBytes = 10485760,
  [switch]$HealthServer,
  [string]$HealthHost = "127.0.0.1",
  [int]$HealthPort = 8081,
  [switch]$Status
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

  $outputMode = if ($Output -eq "Push") { "file,http" } else { "file" }
  $nodeArgs = @(
    "--config", $Config,
    "--output-mode", $outputMode,
    "--out-file", $OutFile,
    "--latest-file", $LatestFile,
    "--state-path", $StatePath,
    "--spool-dir", $SpoolDir,
    "--interval-seconds", [string]$IntervalSeconds,
    "--spool-max-files", [string]$SpoolMaxFiles,
    "--spool-max-bytes", [string]$SpoolMaxBytes,
    "--health-host", $HealthHost,
    "--health-port", [string]$HealthPort
  )
  if ($MaxIterations -gt 0) { $nodeArgs += @("--max-iterations", [string]$MaxIterations) }
  if ($HubUrl) { $nodeArgs += @("--hub-url", $HubUrl) }
  if ($HubBatchUrl) { $nodeArgs += @("--hub-batch-url", $HubBatchUrl) }
  if ($HealthServer) { $nodeArgs += "--health-server" }
  if ($Status) { $nodeArgs += "--status" }

  & npm --silent run server:daemon -- $nodeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "server daemon failed"
  }
} finally {
  Pop-Location
  Restore-Env
}
