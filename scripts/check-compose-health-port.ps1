$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$rootComposePath = Join-Path $repoRoot "docker-compose.yml"
$laxComposePath = Join-Path $repoRoot "deploy/lax/docker-compose.yml.example"

$rootCompose = Get-Content -LiteralPath $rootComposePath -Raw
$laxCompose = Get-Content -LiteralPath $laxComposePath -Raw

$rootSplitOk = $rootCompose.Contains('127.0.0.1:${HEALTH_HOST_PORT:-18081}:8081') -and
  $rootCompose.Contains('HEALTH_PORT: ${HEALTH_PORT:-8081}')
$laxSplitOk = $laxCompose.Contains('127.0.0.1:${HEALTH_HOST_PORT:-18081}:${HEALTH_PORT:-8081}') -and
  $laxCompose.Contains('HEALTH_PORT: ${HEALTH_PORT:-8081}')

$ok = $rootSplitOk -and $laxSplitOk

Write-Output "root_health_port_split_ok=$($rootSplitOk.ToString().ToLowerInvariant())"
Write-Output "lax_health_port_split_ok=$($laxSplitOk.ToString().ToLowerInvariant())"
Write-Output "health_host_port_expected=18081"
Write-Output "health_container_port_expected=8081"
Write-Output "compose_health_port_check_ok=$($ok.ToString().ToLowerInvariant())"

if (-not $ok) {
  exit 1
}
