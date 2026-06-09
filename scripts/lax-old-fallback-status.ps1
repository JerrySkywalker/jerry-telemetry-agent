param(
  [string]$SshHost = "lax",
  [string]$HubBaseUrl = "https://telemetry.jerryskywalker.space"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function ConvertTo-ShellSingleQuoted {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + ($Value -replace "'", "'\''") + "'"
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  throw "Required command not found: ssh"
}
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
  throw "Required command not found: scp"
}

$remoteScript = @'
set -u

print_check() {
  printf '%s=%s\n' "$1" "$2"
}

json_get() {
  file="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    def latest(obj):
        if isinstance(obj, dict):
            events = obj.get("events")
            if isinstance(events, list) and events:
                return events[0]
            return obj.get("event") or obj
        return {}

    def payload(event):
        if not isinstance(event, dict):
            return {}
        envelope = event.get("envelope")
        if isinstance(envelope, dict) and isinstance(envelope.get("payload"), dict):
            return envelope["payload"]
        return event.get("payload") if isinstance(event.get("payload"), dict) else {}

    event = latest(data)
    body = payload(event)
    source = event.get("source") if isinstance(event.get("source"), dict) else {}
    node = body.get("node") if isinstance(body.get("node"), dict) else {}
    values = {
        "hub_latest_codex_status_event_id": event.get("id", ""),
        "hub_latest_codex_status_received_at": event.get("received_at", ""),
        "hub_latest_codex_status_observed_at": event.get("captured_at", "") or body.get("observed_at", ""),
        "hub_latest_codex_status_node_id": node.get("id", "") or body.get("node_id", ""),
        "hub_latest_codex_status_collector": source.get("collector", "") or body.get("collector", ""),
        "hub_latest_codex_status_present": True,
    }
    for key, value in values.items():
        if isinstance(value, bool):
            value = "true" if value else "false"
        print(f"{key}={value}")
except Exception as exc:
    print("hub_latest_codex_status_present=false")
    print(f"hub_latest_codex_status_parse_error={type(exc).__name__}")
PY
  else
    print_check hub_latest_codex_status_present unknown
    print_check hub_latest_codex_status_parse_error python_missing
  fi
}

hub_base="${HUB_BASE_URL%/}"

print_check ssh_ok true

if [ -d "$HOME/codex-status-collector" ]; then
  print_check old_collector_dir_exists true
else
  print_check old_collector_dir_exists false
fi

if [ -d "$HOME/jerry-telemetry-codex-status" ]; then
  print_check old_sender_dir_exists true
else
  print_check old_sender_dir_exists false
fi

service_active="$(systemctl is-active codex-status-telemetry.service 2>/dev/null || true)"
[ -n "$service_active" ] || service_active=unknown
print_check old_service_active "$service_active"

service_enabled="$(systemctl is-enabled codex-status-telemetry.service 2>/dev/null || true)"
[ -n "$service_enabled" ] || service_enabled=unknown
print_check old_service_enabled "$service_enabled"

timer_active="$(systemctl is-active codex-status-telemetry.timer 2>/dev/null || true)"
[ -n "$timer_active" ] || timer_active=unknown
print_check old_timer_active "$timer_active"

timer_enabled="$(systemctl is-enabled codex-status-telemetry.timer 2>/dev/null || true)"
[ -n "$timer_enabled" ] || timer_enabled=unknown
print_check old_timer_enabled "$timer_enabled"

if curl -fsS "$hub_base/v1/events/latest/codex.status" >/tmp/jerry-telemetry-old-codex-status-latest.json 2>/dev/null; then
  json_get /tmp/jerry-telemetry-old-codex-status-latest.json
else
  print_check hub_latest_codex_status_present false
fi

print_check read_only true
print_check modified_timer false
print_check modified_old_files false
'@

$localScript = Join-Path ([IO.Path]::GetTempPath()) ("lax-old-fallback-status-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remotePath = "/tmp/lax-old-fallback-status-$([Guid]::NewGuid().ToString("N")).sh"
try {
  [IO.File]::WriteAllText($localScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  scp $localScript "${SshHost}:$remotePath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy old fallback status script to LAX."
  }

  $remoteCommand = "HUB_BASE_URL=$(ConvertTo-ShellSingleQuoted $HubBaseUrl) bash $(ConvertTo-ShellSingleQuoted $remotePath); rc=`$?; rm -f $(ConvertTo-ShellSingleQuoted $remotePath); exit `$rc"
  ssh $SshHost $remoteCommand
  if ($LASTEXITCODE -ne 0) {
    throw "LAX old fallback status check failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $localScript -ErrorAction SilentlyContinue
}
