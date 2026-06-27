param(
  [string]$NodeConfigPath = ".\deploy\examples\general-linux-agent.node.json",
  [string]$EnvExamplePath = ".\deploy\examples\general-linux-daemon.env.example",
  [string]$InstallRoot = "/opt/jerry-telemetry-agent",
  [string]$StateDir = "/var/lib/jerry-telemetry-agent",
  [string]$LogDir = "/var/log/jerry-telemetry-agent",
  [string]$User = "telemetry-agent",
  [string]$OutputDir = ".smoke\deploy-plan\upgrade"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
  $nodeArgs = @(
    "--action", "upgrade",
    "--node-config-path", $NodeConfigPath,
    "--env-example-path", $EnvExamplePath,
    "--install-root", $InstallRoot,
    "--state-dir", $StateDir,
    "--log-dir", $LogDir,
    "--user", $User,
    "--output-dir", $OutputDir
  )
  & npm --silent run deployment:plan -- $nodeArgs
  if ($LASTEXITCODE -ne 0) { throw "upgrade dry-run plan failed" }
} finally {
  Pop-Location
}
