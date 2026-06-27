param(
  [string]$HubUrl = $(if ($env:TELEMETRY_HUB_URL) { $env:TELEMETRY_HUB_URL } else { "http://127.0.0.1:3000" }),
  [string]$NodeId = "sample-node",
  [string]$WriteSecret = $env:TELEMETRY_NODE_SECRET,
  [string]$ReadToken = $env:TELEMETRY_READ_TOKEN,
  [string]$KeyId = $env:TELEMETRY_NODE_KEY_ID,
  [string]$OutFile = ".smoke\local-agent-e2e\telemetry-batch.safe.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Base-HubUrl {
  param([Parameter(Mandatory = $true)][string]$Value)
  $base = $Value.TrimEnd("/")
  if ($base.EndsWith("/v1/events/batch")) {
    return $base.Substring(0, $base.Length - "/v1/events/batch".Length)
  }
  if ($base.EndsWith("/v1/events")) {
    return $base.Substring(0, $base.Length - "/v1/events".Length)
  }
  return $base
}

try {
  if (-not $WriteSecret -or -not $ReadToken) {
    Write-Host "SKIP smoke-local-agent-e2e reason=missing_dev_secret_or_read_token"
    exit 0
  }

  $baseUrl = Base-HubUrl -Value $HubUrl
  try {
    $health = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/healthz" -Method GET -TimeoutSec 5
    if ($health.StatusCode -lt 200 -or $health.StatusCode -ge 300) {
      throw "unexpected_status"
    }
    Write-Host "PASS hub_healthz"
  } catch {
    Write-Host "FAIL hub_healthz reason=hub_not_reachable"
    exit 1
  }

  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
  $outputPath = Join-Path $repoRoot $OutFile
  New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($outputPath)) | Out-Null

  $args = @(
    "-Mode", "Fixture",
    "-Output", "Push",
    "-HubUrl", $HubUrl,
    "-NodeId", $NodeId,
    "-Region", "local",
    "-Role", "dev-node",
    "-Provider", "local",
    "-WriteSecret", $WriteSecret,
    "-ReadToken", $ReadToken,
    "-OutFile", $outputPath
  )
  if ($KeyId) { $args += @("-KeyId", $KeyId) }

  $agentOutput = & "$PSScriptRoot\agent-once.ps1" @args 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL push_batch reason=agent_push_failed"
    exit 1
  }

  if (-not ($agentOutput -contains "upload=ok")) {
    Write-Host "FAIL push_batch reason=upload_not_confirmed"
    exit 1
  }
  if (-not ($agentOutput -contains "readback=checked")) {
    Write-Host "FAIL readback reason=readback_not_checked"
    exit 1
  }
  if (-not ($agentOutput -contains "readback_node_seen=True") -and -not ($agentOutput -contains "readback_node_seen=true")) {
    Write-Host "FAIL readback reason=node_not_seen"
    exit 1
  }

  Write-Host "PASS push_batch"
  Write-Host "PASS readback"
} catch {
  Write-Host "FAIL smoke-local-agent-e2e reason=safe_failure"
  exit 1
}
