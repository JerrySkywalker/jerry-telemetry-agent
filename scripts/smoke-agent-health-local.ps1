param(
  [string]$OutputDir = ".smoke-agent-health"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-NoForbiddenMarker {
  param([Parameter(Mandatory = $true)][string]$Text)

  $forbidden = @(
    "TELEMETRY_NODE_SECRET=",
    "TELEMETRY_READ_TOKEN=",
    "Authorization: Bearer ",
    ("access" + "_token"),
    ("refresh" + "_token"),
    "id_token",
    "auth.json",
    "BEGIN OPENSSH PRIVATE KEY"
  )

  foreach ($marker in $forbidden) {
    if ($Text.Contains($marker)) {
      throw "Health smoke output contains forbidden marker: $marker"
    }
  }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputRoot = Join-Path $repoRoot $OutputDir
$inputPath = Join-Path $outputRoot "codex-status-fallback-input.json"
$usagePath = Join-Path $outputRoot "codex-usage-latest.safe.snapshot.json"
$lastGoodPath = Join-Path $outputRoot "codex-usage-last-good.safe.snapshot.json"
$healthPath = Join-Path $outputRoot "agent-health-latest.safe.snapshot.json"
$statePath = Join-Path $outputRoot "agent-state.json"
$spoolDir = Join-Path $outputRoot "spool"
New-Item -ItemType Directory -Force -Path $outputRoot, $spoolDir | Out-Null
Set-Content -LiteralPath $inputPath -Value (@{
  captured_at = "2026-06-10T00:00:00.000Z"
  status = "ok"
} | ConvertTo-Json -Depth 10)

$previousEnv = @{
  AGENT_MODE = $env:AGENT_MODE
  CODEX_PROVIDER = $env:CODEX_PROVIDER
  TELEMETRY_COLLECTOR_MODE = $env:TELEMETRY_COLLECTOR_MODE
  TELEMETRY_OUTPUT_MODE = $env:TELEMETRY_OUTPUT_MODE
  TELEMETRY_OUTPUT_FILE = $env:TELEMETRY_OUTPUT_FILE
  CODEX_STATUS_LATEST_PATH = $env:CODEX_STATUS_LATEST_PATH
  CODEX_USAGE_LATEST_PATH = $env:CODEX_USAGE_LATEST_PATH
  CODEX_USAGE_LAST_GOOD_PATH = $env:CODEX_USAGE_LAST_GOOD_PATH
  TELEMETRY_AGENT_HEALTH_ENABLED = $env:TELEMETRY_AGENT_HEALTH_ENABLED
  TELEMETRY_AGENT_HEALTH_OUTPUT_FILE = $env:TELEMETRY_AGENT_HEALTH_OUTPUT_FILE
  STATE_PATH = $env:STATE_PATH
  SPOOL_DIR = $env:SPOOL_DIR
  TELEMETRY_NODE_ID = $env:TELEMETRY_NODE_ID
  TELEMETRY_HOSTNAME = $env:TELEMETRY_HOSTNAME
  TELEMETRY_REGION = $env:TELEMETRY_REGION
  TELEMETRY_COLLECTOR = $env:TELEMETRY_COLLECTOR
  HEALTH_SERVER_ENABLED = $env:HEALTH_SERVER_ENABLED
}

Push-Location $repoRoot
try {
  $env:AGENT_MODE = "once"
  $env:CODEX_PROVIDER = "file"
  $env:TELEMETRY_COLLECTOR_MODE = "codex-cli-status-fallback"
  $env:TELEMETRY_OUTPUT_MODE = "file"
  $env:TELEMETRY_OUTPUT_FILE = $usagePath
  $env:CODEX_STATUS_LATEST_PATH = $inputPath
  $env:CODEX_USAGE_LATEST_PATH = $usagePath
  $env:CODEX_USAGE_LAST_GOOD_PATH = $lastGoodPath
  $env:TELEMETRY_AGENT_HEALTH_ENABLED = "true"
  $env:TELEMETRY_AGENT_HEALTH_OUTPUT_FILE = $healthPath
  $env:STATE_PATH = $statePath
  $env:SPOOL_DIR = $spoolDir
  $env:TELEMETRY_NODE_ID = "local-agent-health-smoke"
  $env:TELEMETRY_HOSTNAME = $env:COMPUTERNAME
  $env:TELEMETRY_REGION = "local"
  $env:TELEMETRY_COLLECTOR = "codex-backend-usage"
  $env:HEALTH_SERVER_ENABLED = "false"

  npm run dev -- --once --health --collector codex-cli-status-fallback
  if ($LASTEXITCODE -ne 0) {
    throw "Agent health smoke run failed with exit code $LASTEXITCODE"
  }

  if (-not (Test-Path -LiteralPath $healthPath -PathType Leaf)) {
    throw "Health snapshot was not written."
  }

  $healthText = Get-Content -Raw -LiteralPath $healthPath
  Assert-NoForbiddenMarker -Text $healthText
  $health = $healthText | ConvertFrom-Json

  if ($health.type -ne "telemetry.agent.health") { throw "Health event type mismatch." }
  if ($health.schema_version -ne 1) { throw "Health schema version mismatch." }
  if ($health.node.id -ne "local-agent-health-smoke") { throw "Health node id mismatch." }
  if ($null -eq $health.status.ok) { throw "Health status.ok missing." }
  if ($null -eq $health.outputs.pending_spool_count) { throw "Health pending_spool_count missing." }
  if ($health.security.node_secret_present -ne $false) { throw "Local smoke should not require a node secret." }

  Write-Host "health_output_path=$healthPath"
  Write-Host "event_type=$($health.type)"
  Write-Host "node_id=$($health.node.id)"
  Write-Host "status_ok=$($health.status.ok)"
  Write-Host "pending_spool_count=$($health.outputs.pending_spool_count)"
  Write-Host "latest_limits_count=$($health.collectors[0].latest_limits_count)"
  Write-Host "observed_at=$($health.observed_at)"
} finally {
  Pop-Location
  foreach ($key in $previousEnv.Keys) {
    if ($null -eq $previousEnv[$key]) {
      Remove-Item -Path "Env:$key" -ErrorAction SilentlyContinue
    } else {
      Set-Item -Path "Env:$key" -Value $previousEnv[$key]
    }
  }
}
