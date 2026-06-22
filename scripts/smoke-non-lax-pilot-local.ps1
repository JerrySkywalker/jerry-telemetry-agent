$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$smokeRoot = Join-Path $repoRoot ".smoke\non-lax-pilot"
$stateDir = Join-Path $smokeRoot "state"
$spoolDir = Join-Path $stateDir "spool"
$healthFile = Join-Path $stateDir "agent-health-latest.safe.snapshot.json"
$statePath = Join-Path $stateDir "agent-state.json"
$nodeConfigPath = Join-Path $repoRoot "deploy\examples\non-lax-agent-health.node.json"

Push-Location $repoRoot
try {
  if (Test-Path $smokeRoot) {
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $spoolDir | Out-Null

  $env:AGENT_MODE = "once"
  $env:TELEMETRY_NODE_CONFIG_PATH = $nodeConfigPath
  $env:TELEMETRY_OUTPUT_MODE = "file"
  $env:TELEMETRY_AGENT_HEALTH_ENABLED = "true"
  $env:TELEMETRY_AGENT_HEALTH_OUTPUT_FILE = $healthFile
  $env:STATE_PATH = $statePath
  $env:SPOOL_DIR = $spoolDir
  $env:TELEMETRY_HUB_URL = "https://telemetry.jerryskywalker.space/v1/events"
  $env:TELEMETRY_NODE_SECRET = '${TELEMETRY_NODE_SECRET_MANUALLY_SUPPLIED}'

  node dist/src/main.js --once | Out-Null

  $health = Get-Content -Raw -LiteralPath $healthFile | ConvertFrom-Json
  $envelopeScriptPath = Join-Path $smokeRoot "verify-envelope.mjs"
  $envelopeScript = @'
import { loadConfig } from "../../dist/src/config.js";
import { buildEnvelope } from "../../dist/src/telemetry/envelope.js";
import { readFileSync } from "node:fs";
const config = loadConfig(process.env, ["--once"]);
const health = JSON.parse(readFileSync(process.env.TELEMETRY_AGENT_HEALTH_OUTPUT_FILE, "utf8"));
const envelope = buildEnvelope(config, health, health.observed_at);
const scanEnvelope = JSON.parse(JSON.stringify(envelope));
delete scanEnvelope.payload?.raw_omitted_keys;
console.log(JSON.stringify({
  event_type: envelope.event_type,
  node_id: envelope.source.node_id,
  collector: envelope.source.collector,
  forbidden_marker_present: /(access_token|refresh_token|id_token|Authorization|Cookie|auth_json|raw_response|account_id|user_id|email)/i.test(JSON.stringify(scanEnvelope))
}));
'@
  Set-Content -LiteralPath $envelopeScriptPath -Value $envelopeScript -Encoding UTF8
  $envelopeJson = node $envelopeScriptPath
  $envelope = $envelopeJson | ConvertFrom-Json

  $ok = $true
  $ok = $ok -and ($health.type -eq "telemetry.agent.health")
  $ok = $ok -and ($health.node.id -eq "example-node-01")
  $ok = $ok -and ($envelope.event_type -eq "telemetry.agent.health")
  $ok = $ok -and ($envelope.node_id -eq "example-node-01")
  $ok = $ok -and ($envelope.collector -eq "agent-health")
  $ok = $ok -and (-not $envelope.forbidden_marker_present)

  [pscustomobject]@{
    ok = [bool]$ok
    node_id_ok = [bool]($health.node.id -eq "example-node-01")
    health_event_ok = [bool]($health.type -eq "telemetry.agent.health")
    envelope_event_ok = [bool]($envelope.event_type -eq "telemetry.agent.health")
    envelope_node_ok = [bool]($envelope.node_id -eq "example-node-01")
    collector = [string]$envelope.collector
    forbidden_marker_present = [bool]$envelope.forbidden_marker_present
    collectors_reported = [int]$health.collectors.Count
    http_enabled = [bool]$health.outputs.http_enabled
  } | ConvertTo-Json -Compress

  if (-not $ok) {
    throw "Non-LAX pilot smoke failed."
  }
} finally {
  Remove-Item Env:\AGENT_MODE -ErrorAction SilentlyContinue
  Remove-Item Env:\TELEMETRY_NODE_CONFIG_PATH -ErrorAction SilentlyContinue
  Remove-Item Env:\TELEMETRY_OUTPUT_MODE -ErrorAction SilentlyContinue
  Remove-Item Env:\TELEMETRY_AGENT_HEALTH_ENABLED -ErrorAction SilentlyContinue
  Remove-Item Env:\TELEMETRY_AGENT_HEALTH_OUTPUT_FILE -ErrorAction SilentlyContinue
  Remove-Item Env:\STATE_PATH -ErrorAction SilentlyContinue
  Remove-Item Env:\SPOOL_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:\TELEMETRY_HUB_URL -ErrorAction SilentlyContinue
  Remove-Item Env:\TELEMETRY_NODE_SECRET -ErrorAction SilentlyContinue
  Pop-Location
}
