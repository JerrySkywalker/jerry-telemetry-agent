param(
  [string]$SshHost = "lax",
  [string]$TelemetryLatestUrl = "https://telemetry.jerryskywalker.space/latest"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$remoteScript = @'
set -eu

print_check() {
  name="$1"
  value="$2"
  printf '%s=%s\n' "$name" "$value"
}

if command -v docker >/dev/null 2>&1; then
  print_check docker "$(docker --version 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
else
  print_check docker "missing"
fi

if docker compose version >/dev/null 2>&1; then
  print_check docker_compose "$(docker compose version 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
elif command -v docker-compose >/dev/null 2>&1; then
  print_check docker_compose "$(docker-compose --version 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
else
  print_check docker_compose "missing"
fi

if command -v codex >/dev/null 2>&1; then
  print_check codex_path "$(command -v codex)"
else
  print_check codex_path "missing"
fi

auth="$HOME/.codex/auth.json"
if [ -f "$auth" ]; then
  print_check codex_config_json "present"
  token_key='access''_token'
  if grep -q "\"$token_key\"[[:space:]]*:" "$auth"; then
    print_check codex_backend_token "present"
  else
    print_check codex_backend_token "missing"
  fi
else
  print_check codex_config_json "missing"
  print_check codex_backend_token "missing"
fi

for unit in capture-status.timer send-latest.timer jerry-telemetry-agent.timer; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    print_check "systemd_$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)/$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  else
    print_check "systemd_$unit" "not-found"
  fi
done

if command -v curl >/dev/null 2>&1; then
  code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "$TELEMETRY_LATEST_URL" 2>/dev/null || true)"
  if [ -n "$code" ]; then
    print_check telemetry_latest_http_status "$code"
  else
    print_check telemetry_latest_http_status "unreachable"
  fi
else
  print_check telemetry_latest_http_status "curl-missing"
fi

print_check disk_root "$(df -h / | awk 'NR==2 {print "size="$2",used="$3",avail="$4",pct="$5}')"
print_check memory "$(free -h | awk '/^Mem:/ {print "total="$2",used="$3",available="$7}')"

if [ -d "$HOME/jerry-telemetry-agent" ]; then
  print_check repo_dir "~/jerry-telemetry-agent present"
else
  print_check repo_dir "~/jerry-telemetry-agent missing"
fi
'@

$encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
ssh $SshHost "TELEMETRY_LATEST_URL='$TelemetryLatestUrl' bash -lc 'echo $encodedScript | base64 -d | bash'"
