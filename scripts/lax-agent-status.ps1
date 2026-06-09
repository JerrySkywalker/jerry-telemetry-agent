param(
  [string]$SshHost = "lax",
  [string]$ProjectDir = "~/jerry-telemetry-agent",
  [string]$HubBaseUrl = "https://telemetry.jerryskywalker.space",
  [string]$ComposeProject = "jerry-telemetry-agent"
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

expand_path() {
  value="$1"
  if [ "$value" = "~" ]; then
    printf '%s\n' "$HOME"
  elif [ "${value#\~/}" != "$value" ]; then
    printf '%s/%s\n' "$HOME" "${value#\~/}"
  else
    printf '%s\n' "$value"
  fi
}

json_get() {
  file="$1"
  program="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$program" <<'PY'
import json
import sys

path = sys.argv[1]
program = sys.argv[2]
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
    values = {}
    if program == "health":
        values = {
            "healthz_ok": data.get("ok") is True,
            "node_id": data.get("node_id", ""),
            "hostname": data.get("hostname", ""),
            "collector": data.get("collector", ""),
            "last_success": data.get("last_success", ""),
            "last_usage_success": data.get("last_usage_success", ""),
            "pending_spool_count": data.get("pending_spool_count", ""),
        }
    elif program == "snapshot":
        limits = data.get("limits")
        status = data.get("status") if isinstance(data.get("status"), dict) else {}
        values = {
            "latest_snapshot_status_ok": status.get("ok") is True,
            "latest_snapshot_limits_count": len(limits) if isinstance(limits, list) else "",
            "latest_snapshot_observed_at": data.get("observed_at", ""),
        }
    elif program == "hub":
        values = {
            "hub_latest_event_id": event.get("id", "") if isinstance(event, dict) else "",
            "hub_latest_received_at": event.get("received_at", "") if isinstance(event, dict) else "",
            "hub_latest_observed_at": (event.get("captured_at") if isinstance(event, dict) else "") or body.get("observed_at", ""),
        }
    elif program == "node":
        values = {
            "node_latest_event_id": event.get("id", "") if isinstance(event, dict) else "",
            "node_latest_received_at": event.get("received_at", "") if isinstance(event, dict) else "",
            "node_latest_observed_at": (event.get("captured_at") if isinstance(event, dict) else "") or body.get("observed_at", ""),
        }
    for key, value in values.items():
        if isinstance(value, bool):
            value = "true" if value else "false"
        print(f"{key}={value}")
except Exception as exc:
    print(f"{program}_parse_error={type(exc).__name__}")
PY
  else
    print_check "${program}_parse_error" "python_missing"
  fi
}

project_dir="$(expand_path "$PROJECT_DIR")"
hub_base="${HUB_BASE_URL%/}"

print_check ssh_ok true
if [ -d "$project_dir" ]; then
  print_check project_dir_exists true
else
  print_check project_dir_exists false
  exit 0
fi

cd "$project_dir" || exit 0

compose() {
  docker compose --env-file .env -p "$COMPOSE_PROJECT" -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml "$@"
}

if [ -f .env ]; then
  print_check env_file_exists true
  secret_key="TELEMETRY_NODE_SECRET"
  if grep -q "^${secret_key}=." .env; then
    print_check env_secret_nonempty true
  else
    print_check env_secret_nonempty false
  fi
  print_check env_file_mode "$(stat -c '%a' .env 2>/dev/null || echo unknown)"
else
  print_check env_file_exists false
  print_check env_secret_nonempty false
  print_check env_file_mode missing
fi

env_backup_count="$(find . -maxdepth 1 -type f -name '.env.bak.*' 2>/dev/null | wc -l | tr -d ' ')"
print_check env_backup_count "$env_backup_count"
env_backups_mode_safe=true
for file in ./.env.bak.*; do
  [ -e "$file" ] || continue
  mode="$(stat -c '%a' "$file" 2>/dev/null || echo unknown)"
  case "$mode" in
    600|400) ;;
    *) env_backups_mode_safe=false ;;
  esac
done
print_check env_backups_mode_safe "$env_backups_mode_safe"

if compose ps >/tmp/jerry-telemetry-agent-ps.txt 2>/tmp/jerry-telemetry-agent-ps.err; then
  if grep -qi 'jerry-telemetry-agent' /tmp/jerry-telemetry-agent-ps.txt && grep -Eqi 'Up|running' /tmp/jerry-telemetry-agent-ps.txt; then
    print_check container_running true
  else
    print_check container_running false
  fi
else
  print_check container_running false
fi

container_id="$(compose ps -q jerry-telemetry-agent 2>/dev/null | head -n1 || true)"
if [ -n "$container_id" ] && docker exec "$container_id" sh -c '[ -n "${TELEMETRY_NODE_SECRET:-}" ]' >/dev/null 2>&1; then
  print_check container_secret_nonempty true
else
  print_check container_secret_nonempty false
fi

config_stderr="$(compose config >/tmp/jerry-telemetry-agent-compose-config.txt 2>&1 || true)"
if grep -q 'TELEMETRY_NODE_SECRET.*unset' /tmp/jerry-telemetry-agent-compose-config.txt 2>/dev/null; then
  print_check compose_config_with_env warning
else
  print_check compose_config_with_env ok
fi

if curl -fsS http://127.0.0.1:18081/healthz >/tmp/jerry-telemetry-agent-healthz.json 2>/dev/null; then
  json_get /tmp/jerry-telemetry-agent-healthz.json health
else
  print_check healthz_ok false
  print_check node_id ""
  print_check hostname ""
  print_check collector ""
  print_check last_success ""
  print_check last_usage_success ""
  print_check pending_spool_count ""
fi

if curl -fsS http://127.0.0.1:18081/api/codex/usage/latest >/tmp/jerry-telemetry-agent-latest.json 2>/dev/null; then
  json_get /tmp/jerry-telemetry-agent-latest.json snapshot
elif [ -n "$container_id" ]; then
  if docker exec "$container_id" sh -c 'cat /state/codex-usage-latest.safe.snapshot.json' >/tmp/jerry-telemetry-agent-latest.json 2>/tmp/jerry-telemetry-agent-latest.err; then
    json_get /tmp/jerry-telemetry-agent-latest.json snapshot
  else
    print_check latest_snapshot_status_ok unknown
    print_check latest_snapshot_limits_count unknown
    print_check latest_snapshot_observed_at unknown
  fi
else
  print_check latest_snapshot_status_ok unknown
  print_check latest_snapshot_limits_count unknown
  print_check latest_snapshot_observed_at unknown
fi

if curl -fsS "$hub_base/v1/events/latest/codex.usage.snapshot" >/tmp/jerry-telemetry-agent-hub-latest.json 2>/dev/null; then
  json_get /tmp/jerry-telemetry-agent-hub-latest.json hub
else
  print_check hub_latest_event_id ""
  print_check hub_latest_received_at ""
  print_check hub_latest_observed_at ""
fi

if curl -fsS "$hub_base/v1/nodes/us-lax-pro-01/latest" >/tmp/jerry-telemetry-agent-node-latest.json 2>/dev/null; then
  json_get /tmp/jerry-telemetry-agent-node-latest.json node
else
  print_check node_latest_event_id ""
  print_check node_latest_received_at ""
  print_check node_latest_observed_at ""
fi

old_timer_active="$(systemctl is-active codex-status-telemetry.timer 2>/dev/null || true)"
[ -n "$old_timer_active" ] || old_timer_active=unknown
print_check old_timer_active "$old_timer_active"
old_timer_enabled="$(systemctl is-enabled codex-status-telemetry.timer 2>/dev/null || true)"
[ -n "$old_timer_enabled" ] || old_timer_enabled=unknown
print_check old_timer_enabled "$old_timer_enabled"
'@

$localScript = Join-Path ([IO.Path]::GetTempPath()) ("lax-agent-status-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remotePath = "/tmp/lax-agent-status-$([Guid]::NewGuid().ToString("N")).sh"
try {
  [IO.File]::WriteAllText($localScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  scp $localScript "${SshHost}:$remotePath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy status script to LAX."
  }

  $remoteCommand = "PROJECT_DIR=$(ConvertTo-ShellSingleQuoted $ProjectDir) HUB_BASE_URL=$(ConvertTo-ShellSingleQuoted $HubBaseUrl) COMPOSE_PROJECT=$(ConvertTo-ShellSingleQuoted $ComposeProject) bash $(ConvertTo-ShellSingleQuoted $remotePath); rc=`$?; rm -f $(ConvertTo-ShellSingleQuoted $remotePath); exit `$rc"
  ssh $SshHost $remoteCommand
  if ($LASTEXITCODE -ne 0) {
    throw "LAX status check failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $localScript -ErrorAction SilentlyContinue
}
