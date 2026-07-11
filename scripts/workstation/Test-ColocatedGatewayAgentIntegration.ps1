param(
  [Parameter(Mandatory = $true)][string]$GatewayRepoPath,
  [Parameter(Mandatory = $true)][string]$GatewayArtifactPath,
  [Parameter(Mandatory = $true)][string]$GatewayManifestPath,
  [Parameter(Mandatory = $true)][string]$AgentArtifactPath,
  [Parameter(Mandatory = $true)][string]$AgentManifestPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True { param([bool]$Condition, [string]$Code); if (-not $Condition) { throw $Code } }
function Get-FreeLoopbackPort {
  $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}
function Wait-JsonEndpoint {
  param([string]$Uri, [int]$Attempts = 60)
  for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
    try { return Invoke-RestMethod -Uri $Uri -TimeoutSec 1 } catch { Start-Sleep -Milliseconds 250 }
  }
  throw "loopback_endpoint_not_ready"
}
function Stop-FixtureProcess {
  param($Process)
  if (-not $Process) { return }
  $pending = @([int]$Process.Id)
  $ordered = New-Object System.Collections.Generic.List[int]
  while ($pending.Count -gt 0) {
    $parent = $pending[0]
    $pending = @($pending | Select-Object -Skip 1)
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$parent" -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.ProcessId })
    foreach ($child in $children) { $pending += $child; $ordered.Add($child) }
  }
  for ($index = $ordered.Count - 1; $index -ge 0; $index--) {
    Stop-Process -Id $ordered[$index] -Force -ErrorAction SilentlyContinue
  }
  Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
  try { $Process.WaitForExit(5000) | Out-Null } catch { }
}
function Start-FixturePowerShell {
  param([string[]]$Arguments, [string]$OutFile, [string]$ErrFile)
  return Start-Process -FilePath "powershell.exe" -ArgumentList $Arguments -WindowStyle Hidden -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -PassThru
}
function Wait-FixtureProcess {
  param($Process, [int]$TimeoutMilliseconds = 30000)
  $completed = $Process.WaitForExit($TimeoutMilliseconds)
  if ($completed) {
    $Process.WaitForExit()
    $Process.Refresh()
  }
  return [pscustomobject]@{
    completed = $completed
    exit_code = if ($completed) { [int]$Process.ExitCode } else { $null }
  }
}
function Assert-LogSafe {
  param([string[]]$Paths, [string]$FixtureSecret)
  $text = ($Paths | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-Content -Raw -LiteralPath $_ }) -join ""
  Assert-True (-not $text.Contains($FixtureSecret)) "fixture_secret_leaked_to_log"
  Assert-True (-not ($text -match "(?i)-----BEGIN .*PRIVATE KEY-----|Bearer\s+|gh[pousr]_|sk-[A-Za-z0-9]{10,}")) "secret_like_marker_in_log"
}
function Get-SafeProcessDiagnostic {
  param([string[]]$Paths, [string]$FixtureSecret, [string]$FixtureRoot)
  $text = ($Paths | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-Content -Raw -LiteralPath $_ }) -join [Environment]::NewLine
  Assert-True (-not $text.Contains($FixtureSecret)) "fixture_secret_leaked_to_log"
  Assert-True (-not ($text -match "(?i)-----BEGIN .*PRIVATE KEY-----|Bearer\s+|gh[pousr]_|sk-[A-Za-z0-9]{10,}")) "secret_like_marker_in_log"
  $safe = $text.Replace($FixtureRoot, "<fixture-root>").Replace("`r", " ").Replace("`n", " ").Trim()
  if ($safe.Length -gt 600) { $safe = $safe.Substring(0, 600) }
  return $safe
}
function Write-Utf8NoBom {
  param([string]$Path, [string]$Text)
  [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

$gatewayRepo = (Resolve-Path -LiteralPath $GatewayRepoPath).Path
$gatewayVerifier = Join-Path $gatewayRepo "scripts\workstation\Test-GatewayReleaseManifest.ps1"
$agentRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$agentVerifier = Join-Path $agentRepo "scripts\workstation\Test-AgentReleaseManifest.ps1"
& $gatewayVerifier -ArtifactPath $GatewayArtifactPath -ManifestPath $GatewayManifestPath | Out-Null
& $agentVerifier -ArtifactPath $AgentArtifactPath -ManifestPath $AgentManifestPath | Out-Null

$gatewayManifest = Get-Content -Raw -LiteralPath $GatewayManifestPath | ConvertFrom-Json
$agentManifest = Get-Content -Raw -LiteralPath $AgentManifestPath | ConvertFrom-Json
$root = Join-Path ([IO.Path]::GetTempPath()) ("mg44-colocated-" + [guid]::NewGuid().ToString("N"))
$gatewayRoot = Join-Path $root "gateway-release"
$agentRoot = Join-Path $root "agent-release"
$configRoot = Join-Path $root "config"
$stateRoot = Join-Path $root "state"
$logRoot = Join-Path $root "logs"
$secretPath = Join-Path $root "protected\fixture-secret"
$gatewayProcess = $null; $disabledProcess = $null; $enabledProcess = $null; $mockProcess = $null
$gatewayPort = Get-FreeLoopbackPort; $agentHealthPort = Get-FreeLoopbackPort; $hubPort = Get-FreeLoopbackPort
$fixtureSecret = ("fixture-" + "signing-" + "material-" + [guid]::NewGuid().ToString("N"))
$logs = @()
$stage = "extract_and_verify"
$failure = $null
$result = $null

try {
  New-Item -ItemType Directory -Force -Path $gatewayRoot, $agentRoot, $configRoot, $stateRoot, $logRoot, (Split-Path -Parent $secretPath), (Join-Path $stateRoot "spool") | Out-Null
  Expand-Archive -LiteralPath $GatewayArtifactPath -DestinationPath $gatewayRoot
  Expand-Archive -LiteralPath $AgentArtifactPath -DestinationPath $agentRoot
  Copy-Item -LiteralPath $GatewayManifestPath -Destination (Join-Path $gatewayRoot "release-manifest.json")
  Copy-Item -LiteralPath $AgentManifestPath -Destination (Join-Path $agentRoot "release-manifest.json")
  & $gatewayVerifier -ArtifactPath $GatewayArtifactPath -ManifestPath $GatewayManifestPath -ExtractedRoot $gatewayRoot | Out-Null
  & $agentVerifier -ArtifactPath $AgentArtifactPath -ManifestPath $AgentManifestPath -ExtractedRoot $agentRoot | Out-Null
  Write-Utf8NoBom $secretPath $fixtureSecret

  $stage = "gateway_artifact_boot"
  $gatewayConfig = Join-Path $configRoot "gateway.env"
  $gatewayConfigLines = @(
    "NODE_ENV=production", "HOST=127.0.0.1", "PORT=$gatewayPort",
    "JMG_TELEMETRY_READINESS_ENABLED=false", "JMG_TELEMETRY_READINESS_TTL_SECONDS=300",
    "JMG_SERVICE_VERSION=$($gatewayManifest.source_commit)",
    "JMG_PRODUCT_PERSISTENCE_ENABLED=false", "JMG_SQLITE_PRODUCT_STORE_ENABLED=false",
    "JMG_DELIVERY_WORKER_ENABLED=false", "JMG_DELIVERY_WORKER_AUTOSTART_ENABLED=false",
    "JMG_REAL_SEND_ENABLED=false", "JMG_EXTERNAL_NETWORK_ENABLED=false"
  )
  Write-Utf8NoBom $gatewayConfig ($gatewayConfigLines -join [Environment]::NewLine)
  $gatewayOut = Join-Path $logRoot "gateway.out.log"; $gatewayErr = Join-Path $logRoot "gateway.err.log"; $logs += $gatewayOut, $gatewayErr
  $gatewayProcess = Start-FixturePowerShell @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $gatewayRoot "bin\Start-GatewayRelease.ps1"),
    "-ReleaseRoot", $gatewayRoot, "-ConfigPath", $gatewayConfig
  ) $gatewayOut $gatewayErr
  $health = Wait-JsonEndpoint "http://127.0.0.1:$gatewayPort/healthz"
  Assert-True ($health.ok -eq $true) "gateway_artifact_health_failed"
  $readiness = Invoke-RestMethod -Uri "http://127.0.0.1:$gatewayPort/v1/telemetry/readiness" -TimeoutSec 2
  Assert-True ($readiness.status -eq "not_configured" -and $readiness.freshness_ttl_seconds -eq 300) "gateway_safe_default_failed"
  Assert-True ($readiness.version -eq [string]$gatewayManifest.source_commit) "gateway_version_marker_failed"

  $stage = "agent_disabled_boot"
  $disabledNode = Join-Path $configRoot "agent-disabled.node.json"
  $enabledNode = Join-Path $configRoot "agent-enabled.node.json"
  $nodeBase = [ordered]@{
    node_id = "fixture-workstation-node"; hostname = "fixture-workstation"; region = "local"; role = "message-gateway"; provider = "local"
    collectors = @([ordered]@{ name = "message-gateway-readiness"; enabled = $false; interval_seconds = 60; target = [ordered]@{ url = "http://127.0.0.1:$gatewayPort/v1/telemetry/readiness"; timeout_ms = 1000 } })
  }
  Write-Utf8NoBom $disabledNode ($nodeBase | ConvertTo-Json -Depth 10)
  $nodeBase.collectors[0].enabled = $true
  Write-Utf8NoBom $enabledNode ($nodeBase | ConvertTo-Json -Depth 10)

  $disabledBatch = Join-Path $stateRoot "disabled.batch.safe.json"
  $disabledEnv = Join-Path $configRoot "agent-disabled.env"
  $disabledEnvLines = @(
    "AGENT_MODE=daemon", "SERVER_DAEMON_MAX_ITERATIONS=1", "TELEMETRY_OUTPUT_MODE=file",
    "TELEMETRY_NODE_CONFIG_PATH=$disabledNode", "TELEMETRY_NODE_SECRET_FILE=$secretPath",
    "TELEMETRY_HUB_REQUEST_TIMEOUT_MS=1000", "TELEMETRY_SERVER_BATCH_LATEST_FILE=$disabledBatch",
    "TELEMETRY_BATCH_OUTPUT_FILE=$disabledBatch", "STATE_PATH=$stateRoot\disabled-state.json",
    "SPOOL_DIR=$stateRoot\spool", "AGENT_INTERVAL_SECONDS=1", "HEALTH_SERVER_ENABLED=true",
    "HEALTH_HOST=127.0.0.1", "HEALTH_PORT=$agentHealthPort"
  )
  Write-Utf8NoBom $disabledEnv ($disabledEnvLines -join [Environment]::NewLine)
  $disabledOut = Join-Path $logRoot "agent-disabled.out.log"; $disabledErr = Join-Path $logRoot "agent-disabled.err.log"; $logs += $disabledOut, $disabledErr
  $disabledProcess = Start-FixturePowerShell @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $agentRoot "bin\Start-AgentRelease.ps1"),
    "-ReleaseRoot", $agentRoot, "-EnvPath", $disabledEnv, "-NodeConfigPath", $disabledNode
  ) $disabledOut $disabledErr
  $disabledExit = Wait-FixtureProcess $disabledProcess
  if (-not ($disabledExit.completed -and $disabledExit.exit_code -eq 0)) {
    $exitCode = if ($disabledExit.completed) { [string]$disabledExit.exit_code } else { "still-running" }
    $diagnostic = Get-SafeProcessDiagnostic @($disabledOut, $disabledErr) $fixtureSecret $root
    Write-Host "agent_disabled_exit=$exitCode"
    Write-Host "agent_disabled_diagnostic=$diagnostic"
  }
  Assert-True ($disabledExit.completed -and $disabledExit.exit_code -eq 0) "agent_disabled_artifact_boot_failed"
  $disabledPayload = Get-Content -Raw -LiteralPath $disabledBatch | ConvertFrom-Json
  Assert-True (@($disabledPayload.events | Where-Object { $_.event_type -eq "message.gateway.readiness" }).Count -eq 0) "agent_disabled_collector_emitted_event"

  $stage = "mock_hub_boot"
  $mockScript = Join-Path $root "mock-hub.mjs"; $mockAccepted = Join-Path $stateRoot "mock-hub-accepted.json"; $mockReady = Join-Path $stateRoot "mock-hub-ready"
  $mockSource = @'
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
const port = Number(process.env.FIXTURE_HUB_PORT);
const secret = process.env.FIXTURE_HUB_SECRET;
const accepted = process.env.FIXTURE_ACCEPTED_FILE;
const ready = process.env.FIXTURE_READY_FILE;
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", chunk => { body += chunk; });
  req.on("end", () => {
    const timestamp = String(req.headers["x-telemetry-timestamp"] || "");
    const nonce = String(req.headers["x-telemetry-nonce"] || "");
    const signature = String(req.headers["x-telemetry-signature"] || "");
    const expected = crypto.createHmac("sha256", secret).update(`${timestamp}.${nonce}.${body}`).digest("hex");
    if (!signature || signature !== expected || req.headers["x-telemetry-node"] !== "fixture-workstation-node") {
      res.writeHead(401); res.end(); return;
    }
    const payload = JSON.parse(body);
    const eventTypes = Array.isArray(payload.events) ? payload.events.map(item => item.event_type) : [];
    fs.writeFileSync(accepted, JSON.stringify({ accepted: true, event_types: eventTypes }));
    res.writeHead(202, { "content-type": "application/json" }); res.end(JSON.stringify({ ok: true }));
  });
});
server.listen(port, "127.0.0.1", () => fs.writeFileSync(ready, "ready"));
'@
  Write-Utf8NoBom $mockScript $mockSource
  $oldFixtureEnv = @{}
  foreach ($name in @("FIXTURE_HUB_PORT", "FIXTURE_HUB_SECRET", "FIXTURE_ACCEPTED_FILE", "FIXTURE_READY_FILE")) { $oldFixtureEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }
  $env:FIXTURE_HUB_PORT = [string]$hubPort; $env:FIXTURE_HUB_SECRET = $fixtureSecret; $env:FIXTURE_ACCEPTED_FILE = $mockAccepted; $env:FIXTURE_READY_FILE = $mockReady
  $mockOut = Join-Path $logRoot "mock.out.log"; $mockErr = Join-Path $logRoot "mock.err.log"; $logs += $mockOut, $mockErr
  $mockProcess = Start-Process -FilePath (Join-Path $agentRoot "runtime\node.exe") -ArgumentList @($mockScript) -WindowStyle Hidden -RedirectStandardOutput $mockOut -RedirectStandardError $mockErr -PassThru
  foreach ($name in $oldFixtureEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $oldFixtureEnv[$name], "Process") }
  for ($i = 0; $i -lt 40 -and -not (Test-Path -LiteralPath $mockReady); $i++) { Start-Sleep -Milliseconds 250 }
  Assert-True (Test-Path -LiteralPath $mockReady) "mock_hub_not_ready"

  $stage = "agent_enabled_signed_upload"
  $enabledBatch = Join-Path $stateRoot "enabled.batch.safe.json"; $enabledEnv = Join-Path $configRoot "agent-enabled.env"
  $enabledEnvLines = @(
    "AGENT_MODE=daemon", "SERVER_DAEMON_MAX_ITERATIONS=1", "TELEMETRY_OUTPUT_MODE=file,http",
    "TELEMETRY_NODE_CONFIG_PATH=$enabledNode", "TELEMETRY_NODE_SECRET_FILE=$secretPath",
    "TELEMETRY_NODE_KEY_ID=fixture-key-reference", "TELEMETRY_HUB_BATCH_URL=http://127.0.0.1:$hubPort/v1/events/batch",
    "TELEMETRY_HUB_REQUEST_TIMEOUT_MS=1000", "TELEMETRY_SERVER_BATCH_LATEST_FILE=$enabledBatch",
    "TELEMETRY_BATCH_OUTPUT_FILE=$enabledBatch", "STATE_PATH=$stateRoot\enabled-state.json",
    "SPOOL_DIR=$stateRoot\spool", "AGENT_INTERVAL_SECONDS=1", "HEALTH_SERVER_ENABLED=true",
    "HEALTH_HOST=127.0.0.1", "HEALTH_PORT=$agentHealthPort"
  )
  Write-Utf8NoBom $enabledEnv ($enabledEnvLines -join [Environment]::NewLine)
  $enabledOut = Join-Path $logRoot "agent-enabled.out.log"; $enabledErr = Join-Path $logRoot "agent-enabled.err.log"; $logs += $enabledOut, $enabledErr
  $enabledProcess = Start-FixturePowerShell @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $agentRoot "bin\Start-AgentRelease.ps1"),
    "-ReleaseRoot", $agentRoot, "-EnvPath", $enabledEnv, "-NodeConfigPath", $enabledNode
  ) $enabledOut $enabledErr
  $enabledExit = Wait-FixtureProcess $enabledProcess
  if (-not ($enabledExit.completed -and $enabledExit.exit_code -eq 0)) {
    $exitCode = if ($enabledExit.completed) { [string]$enabledExit.exit_code } else { "still-running" }
    $diagnostic = Get-SafeProcessDiagnostic @($enabledOut, $enabledErr) $fixtureSecret $root
    Write-Host "agent_enabled_exit=$exitCode"
    Write-Host "agent_enabled_diagnostic=$diagnostic"
  }
  Assert-True ($enabledExit.completed -and $enabledExit.exit_code -eq 0) "agent_enabled_artifact_boot_failed"
  Assert-True (Test-Path -LiteralPath $mockAccepted) "mock_hub_did_not_accept_fixture"
  $accepted = Get-Content -Raw -LiteralPath $mockAccepted | ConvertFrom-Json
  Assert-True ($accepted.accepted -eq $true -and @($accepted.event_types) -contains "message.gateway.readiness") "signed_gateway_event_missing"
  Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $stateRoot "spool") -File -ErrorAction SilentlyContinue).Count -eq 0) "fixture_spool_not_empty"

  $stage = "listener_and_log_safety"
  $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $gatewayPort -ErrorAction SilentlyContinue)
  Assert-True ($listeners.Count -gt 0 -and @($listeners | Where-Object { $_.LocalAddress -notin @("127.0.0.1", "::1") }).Count -eq 0) "gateway_listener_not_loopback_only"
  Assert-LogSafe $logs $fixtureSecret

  $result = [ordered]@{
    gateway_artifact_boot_passed = $true; agent_artifact_boot_passed = $true; loopback_only_passed = $true
    safe_defaults_passed = $true; fixture_signed_upload_passed = $true; fixture_spool_zero = $true
    production_contact = $false; service_registered = $false; ssh_used = $false; secret_values_printed = $false
  }
} catch {
  $failure = $_
} finally {
  try {
    Stop-FixtureProcess $enabledProcess; Stop-FixtureProcess $disabledProcess; Stop-FixtureProcess $mockProcess; Stop-FixtureProcess $gatewayProcess
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      $remaining = @(@($gatewayPort, $agentHealthPort, $hubPort) | Where-Object { @(Get-NetTCPConnection -State Listen -LocalPort $_ -ErrorAction SilentlyContinue).Count -gt 0 })
      if ($remaining.Count -eq 0) { break }
      Start-Sleep -Milliseconds 250
    }
    foreach ($port in @($gatewayPort, $agentHealthPort, $hubPort)) {
      Assert-True (@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue).Count -eq 0) "fixture_port_not_released"
    }
    if (Test-Path -LiteralPath $root) {
      $resolved = (Resolve-Path -LiteralPath $root).Path; $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
      if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
    Assert-True (-not (Test-Path -LiteralPath $root)) "fixture_root_not_removed"
  } catch {
    if (-not $failure) { $failure = $_; $stage = "cleanup" }
  }
}

if ($failure) {
  Write-Host "colocated_rehearsal_failed_stage=$stage"
  Write-Host "colocated_rehearsal_error=$($failure.Exception.Message)"
  throw $failure.Exception
}
$result["cleanup_passed"] = $true
$result | ConvertTo-Json -Compress
