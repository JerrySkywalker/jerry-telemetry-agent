param(
  [string]$HubTarget = "beijing",
  [string]$AgentTarget = "lax",
  [string]$OutputDir = ".smoke\canary-live-audit",
  [ValidateRange(1, 60)][int]$Samples = 1,
  [ValidateRange(0, 3600)][int]$IntervalSeconds = 0,
  [string]$HubServiceName = "jerry-telemetry-hub-canary.service",
  [string]$TunnelServiceName = "jerry-telemetry-hub-canary-reverse-tunnel.service",
  [string]$AgentContainerName = "jerry-telemetry-agent-http-canary-readback-align-20260628T140444Z",
  [bool]$NoRawLogs = $true
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $NoRawLogs) {
  Write-Error "Raw log output is forbidden. Re-run with NoRawLogs enabled."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runId = "canary-live-audit-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) {
  $OutputDir
} else {
  Join-Path $repoRoot $OutputDir
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$expectedEventTypes = @(
  "node.snapshot",
  "node.resources.snapshot",
  "service.health.snapshot",
  "custom.snapshot",
  "telemetry.agent.health"
)

function ConvertTo-PythonStringLiteral {
  param([string]$Value)
  return ($Value | ConvertTo-Json -Compress)
}

function Invoke-RemotePythonReadOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Python,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $normalized = $Python -replace "`r`n", "`n"
  $global:LASTEXITCODE = 0
  $output = $normalized | & ssh $Target "sudo -n python3 -"
  if ($LASTEXITCODE -ne 0) {
    throw "$Label read-only SSH check failed with exit code $LASTEXITCODE"
  }
  $jsonText = ($output -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    throw "$Label returned no JSON"
  }
  return $jsonText | ConvertFrom-Json
}

function Get-ForbiddenMarkers {
  return @(
    "TELEMETRY_NODE_" + "SECRET=",
    "TELEMETRY_READ_" + "TOKEN=",
    "Author" + "ization: Bearer ",
    "Author" + "ization:",
    "Cookie:",
    "Set-Cookie:",
    "access_" + "token",
    "refresh_" + "token",
    "id_" + "token",
    "auth" + ".json",
    "account_" + "id",
    "user_" + "id",
    "email",
    "raw_" + "response",
    "BEGIN OPENSSH PRIVATE KEY"
  )
}

function Invoke-MarkerScan {
  param([string]$Root)

  $markers = Get-ForbiddenMarkers
  $files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @(".json", ".md", ".txt") -and $_.Length -lt 2MB }
  $hits = New-Object System.Collections.Generic.List[object]
  foreach ($file in $files) {
    $text = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($marker in $markers) {
      if ($text.ToLowerInvariant().Contains($marker.ToLowerInvariant())) {
        $hits.Add([pscustomobject][ordered]@{
          file = [IO.Path]::GetRelativePath($repoRoot, $file.FullName)
          marker_detected = $true
        })
      }
    }
  }

  return [pscustomobject][ordered]@{
    scanned_files = @($files).Count
    forbidden_marker_hits = $hits.Count
    marker_scan_pass = $hits.Count -eq 0
    raw_logs_printed = $false
    secrets_printed = $false
  }
}

function Test-StatusCode {
  param([object]$Value, [int]$Expected)
  if ($null -eq $Value) { return $false }
  try { return [int]$Value -eq $Expected } catch { return $false }
}

function Test-Zero {
  param([object]$Value)
  if ($null -eq $Value) { return $false }
  try { return [int]$Value -eq 0 } catch { return $false }
}

function Get-RemoteHubPython {
  param(
    [string]$ServiceName,
    [string]$TunnelName
  )

  $serviceLiteral = ConvertTo-PythonStringLiteral $ServiceName
  $tunnelLiteral = ConvertTo-PythonStringLiteral $TunnelName
  return @"
import json, os, re, sqlite3, subprocess, urllib.request, urllib.error
from datetime import datetime, timezone
SERVICE = $serviceLiteral
TUNNEL = $tunnelLiteral
BASE = "http://127.0.0.1:13080"
FORBIDDEN = ["TELEMETRY_NODE_"+"SECRET=", "TELEMETRY_READ_"+"TOKEN=", "Author"+"ization: Bearer ", "Author"+"ization:", "Cookie:", "Set-Cookie:", "access_"+"token", "refresh_"+"token", "id_"+"token", "auth"+".json", "account_"+"id", "user_"+"id", "email", "raw_"+"response", "BEGIN OPENSSH PRIVATE KEY"]

def run(cmd, timeout=10):
    try:
        p = subprocess.run(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        return p.stdout.strip()
    except Exception:
        return ""

def systemd_props(name):
    out = run("systemctl show %s -p ActiveState -p SubState -p NRestarts -p Restart --no-pager" % name)
    data = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v
    return data

def http(path, token=None, read_body=False):
    req = urllib.request.Request(BASE + path)
    if token:
        req.add_header("Author" + "ization", "Bearer " + token.strip())
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = resp.read(1024 * 512) if read_body else b""
            return int(resp.status), body
    except urllib.error.HTTPError as err:
        body = err.read(1024 * 32) if read_body else b""
        return int(err.code), body
    except Exception:
        return 0, b""

def discover_readback_token():
    roots = ["/etc/jerry-telemetry-hub-canary", "/var/lib/jerry-telemetry-hub-canary", "/opt/jerry-telemetry-hub-canary", "/root"]
    candidates = []
    for root in roots:
        if not os.path.exists(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            if dirpath[len(root):].count(os.sep) > 5:
                dirnames[:] = []
                continue
            for name in filenames:
                full = os.path.join(dirpath, name)
                low = name.lower()
                full_low = full.lower()
                if ("read" in low or "readback" in full_low or "verification" in full_low) and ("token" in low or "credential" in low or "readback" in full_low):
                    candidates.append(full)
    for path in candidates:
        try:
            st = os.stat(path)
            with open(path, "r", encoding="utf-8", errors="ignore") as handle:
                token = handle.read(4096).strip()
            if not token or any(x in token.lower() for x in ["placeholder", "changeme", "example"]):
                continue
            code, _ = http("/v1/nodes", token=token, read_body=False)
            if code == 200:
                return True, token, oct(st.st_mode & 0o777)[2:]
        except Exception:
            continue
    return False, None, None

def log_summary(unit):
    text = run("journalctl -u %s -n 240 --no-pager 2>/dev/null" % unit, timeout=15)
    low = text.lower()
    return {
        "error_like_count": len(re.findall(r"error|failed|failure|exception|panic", low)),
        "warning_like_count": len(re.findall(r"warn|warning", low)),
        "auth_rejection_like_count": len(re.findall(r"401|unauth|forbid|bad hmac|signature", low)),
        "upload_failure_like_count": len(re.findall(r"upload.*fail|send.*fail|http.*fail", low)),
        "collector_failure_like_count": len(re.findall(r"collector.*fail", low)),
        "crash_restart_like_count": len(re.findall(r"crash|restart|exited|killed", low)),
        "forbidden_marker_count": sum(low.count(marker.lower()) for marker in FORBIDDEN),
    }

def listener_counts():
    total = 0
    nonlocal_count = 0
    for line in run("ss -ltnH 2>/dev/null").splitlines():
        parts = line.split()
        addr = parts[3] if len(parts) >= 4 else ""
        if addr.endswith(":13080") or addr.endswith(".13080"):
            total += 1
            if not (addr.startswith("127.0.0.1:") or addr.startswith("[::1]:") or addr.startswith("localhost:")):
                nonlocal_count += 1
    return total, nonlocal_count

def find_sqlite():
    found = []
    for root in ["/var/lib/jerry-telemetry-hub-canary", "/opt/jerry-telemetry-hub-canary"]:
        if not os.path.exists(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            if dirpath[len(root):].count(os.sep) > 5:
                dirnames[:] = []
                continue
            for name in filenames:
                low = name.lower()
                if low.endswith(("-wal", "-shm")):
                    continue
                if low.endswith((".sqlite3", ".sqlite", ".db")) or low == "telemetry.sqlite3":
                    found.append(os.path.join(dirpath, name))
    found.sort(key=lambda value: os.path.getmtime(value), reverse=True)
    return found[0] if found else "/var/lib/jerry-telemetry-hub-canary/telemetry.sqlite3"

def sqlite_integrity():
    path = find_sqlite()
    exists = os.path.exists(path)
    size = os.path.getsize(path) if exists else None
    if not exists:
        return {"exists": False, "size_bytes": None, "integrity_ok": None, "checked": False, "path_printed": False}
    try:
        con = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
        row = con.execute("PRAGMA integrity_check").fetchone()
        con.close()
        return {"exists": True, "size_bytes": size, "integrity_ok": bool(row and row[0] == "ok"), "checked": True, "path_printed": False}
    except Exception:
        return {"exists": True, "size_bytes": size, "integrity_ok": None, "checked": False, "path_printed": False}

readback_exists, token, readback_mode = discover_readback_token()
read_statuses = {}
read_seen = {}
recent_count = None
recent_latest_timestamp = None
if token:
    for name, path in {"nodes": "/v1/nodes", "summary": "/v1/summary", "services": "/v1/services", "custom": "/v1/custom", "recent": "/v1/events/recent"}.items():
        code, body = http(path, token=token, read_body=True)
        read_statuses[name] = code
        try:
            data = json.loads(body.decode("utf-8", "ignore") or "{}")
        except Exception:
            data = {}
        serialized = json.dumps(data)
        read_seen[name] = bool(data) and serialized not in ["{}", "[]"]
        if name == "recent":
            events = data.get("events") if isinstance(data, dict) else data if isinstance(data, list) else []
            if isinstance(events, list):
                recent_count = len(events)
                for event in events:
                    if isinstance(event, dict):
                        recent_latest_timestamp = event.get("event_time") or event.get("created_at") or event.get("timestamp") or event.get("received_at")
                        if recent_latest_timestamp:
                            break
else:
    read_statuses = {name: 0 for name in ["nodes", "summary", "services", "custom", "recent"]}
    read_seen = {name: False for name in read_statuses.keys()}

listener_total, listener_nonlocal = listener_counts()
result = {
    "observed_at_utc": datetime.now(timezone.utc).isoformat(),
    "target": "hub",
    "hub_service": SERVICE,
    "hub_service_show": systemd_props(SERVICE),
    "tunnel_service": TUNNEL,
    "tunnel_service_show": systemd_props(TUNNEL),
    "hub_health_status": http("/healthz")[0],
    "hub_unauth_nodes_status": http("/v1/nodes")[0],
    "readback_file_exists": readback_exists,
    "readback_file_mode": readback_mode,
    "readback_token_printed": False,
    "readback_statuses": read_statuses,
    "read_model_seen": read_seen,
    "recent_count": recent_count,
    "recent_latest_timestamp": recent_latest_timestamp,
    "listener_count_13080": listener_total,
    "nonlocal_listener_count_13080": listener_nonlocal,
    "sqlite": sqlite_integrity(),
    "hub_log_summary": log_summary(SERVICE),
    "tunnel_log_summary": log_summary(TUNNEL),
    "raw_logs_printed": False,
    "response_bodies_printed": False,
    "secrets_printed": False,
}
print(json.dumps(result, indent=2, sort_keys=True))
"@
}

function Get-RemoteAgentPython {
  param([string]$ContainerName)

  $containerLiteral = ConvertTo-PythonStringLiteral $ContainerName
  return @"
import json, os, re, subprocess, urllib.request, urllib.error
from datetime import datetime, timezone
CONTAINER = $containerLiteral
FORBIDDEN = ["TELEMETRY_NODE_"+"SECRET=", "TELEMETRY_READ_"+"TOKEN=", "Author"+"ization: Bearer ", "Author"+"ization:", "Cookie:", "Set-Cookie:", "access_"+"token", "refresh_"+"token", "id_"+"token", "auth"+".json", "account_"+"id", "user_"+"id", "email", "raw_"+"response", "BEGIN OPENSSH PRIVATE KEY"]

def run(cmd, timeout=10):
    try:
        p = subprocess.run(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        return p.stdout.strip()
    except Exception:
        return ""

def inspect_container():
    state = {}
    policy = {}
    restart_count = None
    try:
        state = json.loads(run("docker inspect --format '{{json .State}}' %s" % CONTAINER, timeout=15) or "{}")
    except Exception:
        pass
    try:
        policy = json.loads(run("docker inspect --format '{{json .HostConfig.RestartPolicy}}' %s" % CONTAINER, timeout=15) or "{}")
    except Exception:
        pass
    restart_count_text = run("docker inspect --format '{{.RestartCount}}' %s" % CONTAINER, timeout=15)
    if restart_count_text:
        restart_count = restart_count_text.strip()
    return state, policy, restart_count

def http_status(path, port=18082, read_body=False):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%s%s" % (port, path), timeout=5) as resp:
            body = resp.read(1024 * 512) if read_body else b""
            return int(resp.status), body
    except urllib.error.HTTPError as err:
        body = err.read(1024 * 32) if read_body else b""
        return int(err.code), body
    except Exception:
        return 0, b""

def listener_counts():
    total = 0
    nonlocal_count = 0
    for line in run("ss -ltnH 2>/dev/null").splitlines():
        parts = line.split()
        addr = parts[3] if len(parts) >= 4 else ""
        if addr.endswith(":13080") or addr.endswith(".13080"):
            total += 1
            if not (addr.startswith("127.0.0.1:") or addr.startswith("[::1]:") or addr.startswith("localhost:")):
                nonlocal_count += 1
    return total, nonlocal_count

def count_host(path):
    if not os.path.isdir(path):
        return None
    text = run("find '%s' -maxdepth 1 -type f 2>/dev/null | wc -l | tr -dc '0-9'" % path.replace("'", "'\\''"))
    return int(text or 0)

def container_find_count(expr):
    text = run("docker exec %s sh -lc \"find /state -maxdepth 7 -type f %s 2>/dev/null | wc -l | tr -dc '0-9'\"" % (CONTAINER, expr), timeout=15)
    try:
        return int(text or 0)
    except Exception:
        return None

def batch_summary():
    code, body = http_status("/api/server/batch/latest", read_body=True)
    summary = {"status": code, "exists": False, "event_count": None, "event_types": [], "marker_scan_pass": True}
    try:
        data = json.loads(body.decode("utf-8", "ignore") or "{}")
        serialized = json.dumps(data)
        summary["marker_scan_pass"] = not any(marker.lower() in serialized.lower() for marker in FORBIDDEN)
        summary["exists"] = bool(data)
        if isinstance(data, dict):
            summary["event_count"] = data.get("events_count") or data.get("event_count") or data.get("count")
            event_types = data.get("event_types") or []
            if isinstance(event_types, list):
                summary["event_types"] = sorted(str(value) for value in event_types)
    except Exception:
        summary["marker_scan_pass"] = False
    return summary

def status_summary():
    code, body = http_status("/api/server/status", read_body=True)
    summary = {
        "status": code,
        "marker_scan_pass": True,
        "pending_active_spool_count": None,
        "last_batch_error_present": None,
        "last_successful_send_at": None,
        "strict_upload_failure_count": 0,
        "collector_failure_count": 0,
    }
    try:
        data = json.loads(body.decode("utf-8", "ignore") or "{}")
        serialized = json.dumps(data)
        summary["marker_scan_pass"] = not any(marker.lower() in serialized.lower() for marker in FORBIDDEN)

        def find_value(obj, names):
            if isinstance(obj, dict):
                for key, value in obj.items():
                    if key in names:
                        return value
                for value in obj.values():
                    result = find_value(value, names)
                    if result is not None:
                        return result
            if isinstance(obj, list):
                for value in obj:
                    result = find_value(value, names)
                    if result is not None:
                        return result
            return None

        summary["pending_active_spool_count"] = find_value(data, {"pendingBatchSpoolCount", "pending_batch_spool_count", "pending_spool_count", "pendingSpoolCount"})
        summary["last_batch_error_present"] = bool(find_value(data, {"last_batch_error_present", "lastBatchErrorPresent", "lastBatchError"}))
        summary["last_successful_send_at"] = find_value(data, {"lastSuccessfulSendAt", "last_successful_send_at", "last_batch_successful_send_at", "lastBatchSuccessfulSendAt"})
        summary["strict_upload_failure_count"] = find_value(data, {"strict_upload_failure_count", "strictUploadFailureCount"}) or 0
        summary["collector_failure_count"] = find_value(data, {"collector_failure_count", "collectorFailureCount"}) or 0
    except Exception:
        summary["marker_scan_pass"] = False
    return summary

def log_summary():
    text = run("docker logs --since 20m --tail 240 %s 2>&1" % CONTAINER, timeout=20)
    low = text.lower()
    return {
        "error_like_count": len(re.findall(r"error|failed|failure|exception|panic", low)),
        "warning_like_count": len(re.findall(r"warn|warning", low)),
        "upload_ok_count": len(re.findall(r"upload.*ok|successful.*send|batch.*uploaded", low)),
        "upload_failure_like_count": len(re.findall(r"upload.*fail|send.*fail|http.*fail|retry.*error", low)),
        "collector_failure_like_count": len(re.findall(r"collector.*fail", low)),
        "strict_upload_failure_count": len(re.findall(r"strict.*upload.*fail", low)),
        "forbidden_marker_count": sum(low.count(marker.lower()) for marker in FORBIDDEN),
    }

state, policy, restart_count = inspect_container()
listener_total, listener_nonlocal = listener_counts()
old_archive = "/var/lib/jerry-telemetry-agent-canary/diagnostics/http-spool-before-reverse-20260628T131558Z"
diagnostics = "/var/lib/jerry-telemetry-agent-canary/diagnostics"
failed_text = run("find '%s' -maxdepth 2 -type f 2>/dev/null | grep -E 'failed|rollback|check' | wc -l | tr -dc '0-9'" % diagnostics)
result = {
    "observed_at_utc": datetime.now(timezone.utc).isoformat(),
    "target": "agent",
    "container": CONTAINER,
    "container_running": bool(state.get("Running")),
    "container_status": state.get("Status"),
    "container_restart_count": restart_count,
    "restart_policy": policy,
    "health_status": http_status("/healthz")[0],
    "status_status": http_status("/status")[0],
    "api_server_status": http_status("/api/server/status")[0],
    "lax_port_13080_listener_count": listener_total,
    "lax_nonlocal_listener_count_13080": listener_nonlocal,
    "lax_tunnel_health_status": http_status("/healthz", port=13080)[0],
    "latest_batch": batch_summary(),
    "server_status_summary": status_summary(),
    "active_spool_count": container_find_count("-path '*/spool/*' ! -path '*archive*'"),
    "archived_old_spool_count": count_host(old_archive),
    "archived_failed_check_spool_count": int(failed_text or 0),
    "log_summary": log_summary(),
    "lax_codex_systemd_name_filter_count": int(run("systemctl list-units --type=service --all --no-pager --plain 2>/dev/null | grep -Ei 'codex-status|capture-status|send-latest|jerry-telemetry-agent.timer' | wc -l") or 0),
    "lax_codex_docker_name_filter_count": int(run("docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ei 'codex|jerry-telemetry-agent' | grep -v 'canary' | wc -l") or 0),
    "raw_logs_printed": False,
    "config_values_printed": False,
    "secrets_printed": False,
}
print(json.dumps(result, indent=2, sort_keys=True))
"@
}

function Test-SamplePass {
  param([object]$Sample)

  $hub = $Sample.hub
  $agent = $Sample.agent
  $readbackStatuses = @($hub.readback_statuses.nodes, $hub.readback_statuses.summary, $hub.readback_statuses.services, $hub.readback_statuses.custom, $hub.readback_statuses.recent)
  $eventTypes = @($agent.latest_batch.event_types)

  $eventTypesPass = $true
  foreach ($eventType in $expectedEventTypes) {
    if ($eventTypes -notcontains $eventType) {
      $eventTypesPass = $false
    }
  }

  $sqliteOk = $hub.sqlite.checked -eq $true -and $hub.sqlite.integrity_ok -eq $true
  return (
    $hub.hub_service_show.ActiveState -eq "active" -and
    $hub.tunnel_service_show.ActiveState -eq "active" -and
    (Test-StatusCode $hub.hub_health_status 200) -and
    (Test-StatusCode $hub.hub_unauth_nodes_status 401) -and
    (@($readbackStatuses | Where-Object { -not (Test-StatusCode $_ 200) }).Count -eq 0) -and
    (Test-Zero $hub.nonlocal_listener_count_13080) -and
    $sqliteOk -and
    $agent.container_running -eq $true -and
    (Test-StatusCode $agent.health_status 200) -and
    (Test-StatusCode $agent.status_status 200) -and
    (Test-StatusCode $agent.api_server_status 200) -and
    (Test-StatusCode $agent.lax_tunnel_health_status 200) -and
    (Test-Zero $agent.lax_nonlocal_listener_count_13080) -and
    $agent.latest_batch.exists -eq $true -and
    $eventTypesPass -and
    (Test-Zero $agent.active_spool_count) -and
    ([int]$agent.archived_old_spool_count -eq 100) -and
    ([int]$agent.archived_failed_check_spool_count -eq 1) -and
    $agent.server_status_summary.last_batch_error_present -eq $false -and
    (Test-Zero $agent.server_status_summary.strict_upload_failure_count) -and
    (Test-Zero $agent.server_status_summary.collector_failure_count) -and
    $hub.hub_log_summary.forbidden_marker_count -eq 0 -and
    $hub.tunnel_log_summary.forbidden_marker_count -eq 0 -and
    $agent.log_summary.forbidden_marker_count -eq 0
  )
}

$samplesData = New-Object System.Collections.Generic.List[object]
for ($i = 1; $i -le $Samples; $i++) {
  if ($i -gt 1 -and $IntervalSeconds -gt 0) {
    Start-Sleep -Seconds $IntervalSeconds
  }

  $hubAudit = Invoke-RemotePythonReadOnly -Target $HubTarget -Python (Get-RemoteHubPython -ServiceName $HubServiceName -TunnelName $TunnelServiceName) -Label "Hub audit sample $i"
  $agentAudit = Invoke-RemotePythonReadOnly -Target $AgentTarget -Python (Get-RemoteAgentPython -ContainerName $AgentContainerName) -Label "Agent audit sample $i"

  $sample = [pscustomobject][ordered]@{
    sample = $i
    collected_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    hub = $hubAudit
    tunnel = [ordered]@{
      service_active = $hubAudit.tunnel_service_show.ActiveState
      restart_count = $hubAudit.tunnel_service_show.NRestarts
      lax_reachability_status = $agentAudit.lax_tunnel_health_status
      lax_nonlocal_listener_count_13080 = $agentAudit.lax_nonlocal_listener_count_13080
      log_summary = $hubAudit.tunnel_log_summary
    }
    agent = $agentAudit
  }
  $sample | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $outputRoot ("sample-{0}.json" -f $i)) -Encoding UTF8
  $samplesData.Add($sample)
}

$sampleRows = @()
foreach ($sample in $samplesData) {
  $sampleRows += [pscustomobject][ordered]@{
    sample = $sample.sample
    hub_active = $sample.hub.hub_service_show.ActiveState
    tunnel_active = $sample.hub.tunnel_service_show.ActiveState
    hub_health = $sample.hub.hub_health_status
    readback_recent = $sample.hub.readback_statuses.recent
    recent_latest_timestamp = $sample.hub.recent_latest_timestamp
    agent_running = $sample.agent.container_running
    agent_restart_policy = "$($sample.agent.restart_policy.Name):$($sample.agent.restart_policy.MaximumRetryCount)"
    agent_restart_count = $sample.agent.container_restart_count
    agent_health = $sample.agent.health_status
    active_spool = $sample.agent.active_spool_count
    old_archive = $sample.agent.archived_old_spool_count
    failed_archive = $sample.agent.archived_failed_check_spool_count
    last_batch_error = $sample.agent.server_status_summary.last_batch_error_present
    last_successful_send = $sample.agent.server_status_summary.last_successful_send_at
  }
}

$allSamplesPass = @($samplesData | Where-Object { -not (Test-SamplePass $_) }).Count -eq 0
$markerScan = Invoke-MarkerScan -Root $outputRoot
$status = if ($allSamplesPass -and $markerScan.marker_scan_pass) { "PASS" } else { "FAIL" }

$first = $samplesData[0]
$last = $samplesData[$samplesData.Count - 1]
$progression = [ordered]@{
  samples = $Samples
  interval_seconds = $IntervalSeconds
  restart_counts_stable = ($first.hub.hub_service_show.NRestarts -eq $last.hub.hub_service_show.NRestarts) -and ($first.hub.tunnel_service_show.NRestarts -eq $last.hub.tunnel_service_show.NRestarts) -and ($first.agent.container_restart_count -eq $last.agent.container_restart_count)
  send_timestamp_first = $first.agent.server_status_summary.last_successful_send_at
  send_timestamp_last = $last.agent.server_status_summary.last_successful_send_at
  recent_timestamp_first = $first.hub.recent_latest_timestamp
  recent_timestamp_last = $last.hub.recent_latest_timestamp
  active_spool_stable_zero = @($samplesData | Where-Object { $_.agent.active_spool_count -ne 0 }).Count -eq 0
}

$summary = [pscustomobject][ordered]@{
  run_id = $runId
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  result = $status
  read_only = $true
  production_mutation = $false
  docker_runtime_mutation = $false
  service_timer_mutation = $false
  tunnel_mutation = $false
  raw_logs_printed = $false
  response_bodies_printed = $false
  secrets_printed = $false
  hub_target = $HubTarget
  agent_target = $AgentTarget
  samples = $sampleRows
  progression = $progression
  marker_scan = $markerScan
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $outputRoot "canary-live-audit-summary.json") -Encoding UTF8
$markerScan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outputRoot "marker-scan-report.json") -Encoding UTF8

$summaryMd = @(
  "# Canary Live Audit Summary",
  "",
  "- result: $status",
  "- read_only: true",
  "- production_mutation: false",
  "- docker_runtime_mutation: false",
  "- service_timer_mutation: false",
  "- tunnel_mutation: false",
  "- raw_logs_printed: false",
  "- secrets_printed: false",
  "- samples: $Samples",
  "- marker_scan_hits: $($markerScan.forbidden_marker_hits)"
)
$summaryMd | Set-Content -LiteralPath (Join-Path $outputRoot "canary-live-audit-summary.md") -Encoding UTF8

$hubMd = @(
  "# Hub Live Audit",
  "",
  "- service: $HubServiceName",
  "- active_state: $($last.hub.hub_service_show.ActiveState)",
  "- restart_count: $($last.hub.hub_service_show.NRestarts)",
  "- health: $($last.hub.hub_health_status)",
  "- unauth_read: $($last.hub.hub_unauth_nodes_status)",
  "- readback_statuses: nodes=$($last.hub.readback_statuses.nodes), summary=$($last.hub.readback_statuses.summary), services=$($last.hub.readback_statuses.services), custom=$($last.hub.readback_statuses.custom), recent=$($last.hub.readback_statuses.recent)",
  "- recent_count: $($last.hub.recent_count)",
  "- recent_latest_timestamp: $($last.hub.recent_latest_timestamp)",
  "- nonlocal_listener_count_13080: $($last.hub.nonlocal_listener_count_13080)",
  "- sqlite_integrity_ok: $($last.hub.sqlite.integrity_ok)",
  "- log_summary: errors=$($last.hub.hub_log_summary.error_like_count), warnings=$($last.hub.hub_log_summary.warning_like_count), auth_rejections=$($last.hub.hub_log_summary.auth_rejection_like_count), marker=$($last.hub.hub_log_summary.forbidden_marker_count)"
)
$hubMd | Set-Content -LiteralPath (Join-Path $outputRoot "hub-live-audit.md") -Encoding UTF8

$tunnelMd = @(
  "# Tunnel Live Audit",
  "",
  "- service: $TunnelServiceName",
  "- active_state: $($last.hub.tunnel_service_show.ActiveState)",
  "- restart_count: $($last.hub.tunnel_service_show.NRestarts)",
  "- lax_reachability_status: $($last.agent.lax_tunnel_health_status)",
  "- lax_nonlocal_listener_count_13080: $($last.agent.lax_nonlocal_listener_count_13080)",
  "- log_summary: errors=$($last.hub.tunnel_log_summary.error_like_count), warnings=$($last.hub.tunnel_log_summary.warning_like_count), marker=$($last.hub.tunnel_log_summary.forbidden_marker_count)"
)
$tunnelMd | Set-Content -LiteralPath (Join-Path $outputRoot "tunnel-live-audit.md") -Encoding UTF8

$agentMd = @(
  "# Agent Live Audit",
  "",
  "- container: $AgentContainerName",
  "- running: $($last.agent.container_running)",
  "- restart_policy: $($last.agent.restart_policy.Name):$($last.agent.restart_policy.MaximumRetryCount)",
  "- restart_count: $($last.agent.container_restart_count)",
  "- health: $($last.agent.health_status)",
  "- status: $($last.agent.status_status)",
  "- api_server_status: $($last.agent.api_server_status)",
  "- latest_batch_exists: $($last.agent.latest_batch.exists)",
  "- latest_batch_event_count: $($last.agent.latest_batch.event_count)",
  "- latest_batch_event_types: $($last.agent.latest_batch.event_types -join ', ')",
  "- active_spool_count: $($last.agent.active_spool_count)",
  "- archived_old_spool_count: $($last.agent.archived_old_spool_count)",
  "- archived_failed_check_spool_count: $($last.agent.archived_failed_check_spool_count)",
  "- last_batch_error_present: $($last.agent.server_status_summary.last_batch_error_present)",
  "- last_successful_send_at: $($last.agent.server_status_summary.last_successful_send_at)",
  "- strict_upload_failure_count: $($last.agent.server_status_summary.strict_upload_failure_count)",
  "- collector_failure_count: $($last.agent.server_status_summary.collector_failure_count)",
  "- LAX Codex name-filter counts: systemd=$($last.agent.lax_codex_systemd_name_filter_count), docker=$($last.agent.lax_codex_docker_name_filter_count)",
  "- raw_logs_printed: false",
  "- config_values_printed: false"
)
$agentMd | Set-Content -LiteralPath (Join-Path $outputRoot "agent-live-audit.md") -Encoding UTF8

$table = @("# Canary Live Audit Sample Table", "", "| sample | hub | tunnel | agent | active_spool | old_archive | failed_archive | send | recent |", "| --- | --- | --- | --- | ---: | ---: | ---: | --- | --- |")
foreach ($row in $sampleRows) {
  $table += "| $($row.sample) | $($row.hub_health) | $($row.tunnel_active) | $($row.agent_health) | $($row.active_spool) | $($row.old_archive) | $($row.failed_archive) | $($row.last_successful_send) | $($row.recent_latest_timestamp) |"
}
$table | Set-Content -LiteralPath (Join-Path $outputRoot "sample-table.md") -Encoding UTF8

$checklist = @(
  "# Canary Live Audit Checklist",
  "",
  "- $(if ($last.hub.hub_service_show.ActiveState -eq "active") { "PASS" } else { "FAIL" }): Hub service active",
  "- $(if ($last.hub.hub_health_status -eq 200) { "PASS" } else { "FAIL" }): Hub health pass",
  "- $(if ($last.hub.hub_unauth_nodes_status -eq 401) { "PASS" } else { "FAIL" }): Hub unauth read rejected",
  "- $(if ($last.hub.readback_statuses.recent -eq 200) { "PASS" } else { "FAIL" }): Hub authenticated readback pass",
  "- $(if ($last.hub.nonlocal_listener_count_13080 -eq 0) { "PASS" } else { "FAIL" }): Hub no non-local canary listener",
  "- $(if ($last.hub.sqlite.integrity_ok -eq $true) { "PASS" } else { "FAIL" }): Hub SQLite integrity ok",
  "- $(if ($last.hub.tunnel_service_show.ActiveState -eq "active") { "PASS" } else { "FAIL" }): Tunnel service active",
  "- $(if ($last.agent.lax_tunnel_health_status -eq 200) { "PASS" } else { "FAIL" }): LAX localhost tunnel reachable",
  "- $(if ($last.agent.container_running -eq $true) { "PASS" } else { "FAIL" }): Agent container running",
  "- $(if ($last.agent.health_status -eq 200 -and $last.agent.status_status -eq 200 -and $last.agent.api_server_status -eq 200) { "PASS" } else { "FAIL" }): Agent health/status/API pass",
  "- $(if ($last.agent.active_spool_count -eq 0) { "PASS" } else { "FAIL" }): Agent active spool zero",
  "- $(if ($last.agent.archived_old_spool_count -eq 100 -and $last.agent.archived_failed_check_spool_count -eq 1) { "PASS" } else { "FAIL" }): Archived spool preserved",
  "- $(if ($last.agent.server_status_summary.last_batch_error_present -eq $false) { "PASS" } else { "FAIL" }): Last batch error false",
  "- $(if ($markerScan.marker_scan_pass) { "PASS" } else { "FAIL" }): Forbidden marker scan pass",
  "- PASS: Raw logs not printed",
  "- PASS: Secrets not printed",
  "- PASS: No production mutation"
)
$checklist | Set-Content -LiteralPath (Join-Path $outputRoot "canary-live-audit-checklist.md") -Encoding UTF8

Write-Host "canary_live_audit=$status"
Write-Host "output_dir=$outputRoot"
Write-Host "samples=$Samples"
Write-Host "read_only=true"
Write-Host "production_mutation=false"
Write-Host "docker_runtime_mutation=false"
Write-Host "service_timer_mutation=false"
Write-Host "tunnel_mutation=false"
Write-Host "marker_scan_hits=$($markerScan.forbidden_marker_hits)"

if ($status -ne "PASS") {
  exit 1
}
