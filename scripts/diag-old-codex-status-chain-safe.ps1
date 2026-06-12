param(
  [string]$SshHost = "lax"
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

$script = @'
set -u
print(){ printf '%s=%s\n' "$1" "$2"; }
present_file(){ [ -f "$1" ] && echo true || echo false; }
present_dir(){ [ -d "$1" ] && echo true || echo false; }
mtime_file(){ [ -f "$1" ] && stat -c '%Y' "$1" 2>/dev/null || echo missing; }

collector="$HOME/codex-status-collector"
telemetry="$HOME/jerry-telemetry-codex-status"
latest="$collector/logs/latest.json"
send_latest="$collector/send-latest.sh"
capture="$collector/capture-status.sh"

collector_present="$(present_dir "$collector")"
telemetry_present="$(present_dir "$telemetry")"
if [ "$collector_present" = "true" ] || [ "$telemetry_present" = "true" ]; then
  old_dirs=true
else
  old_dirs=false
fi

timer_active="$(systemctl is-active codex-status-telemetry.timer 2>/dev/null || echo not-found)"
timer_enabled="$(systemctl is-enabled codex-status-telemetry.timer 2>/dev/null || echo not-found)"
service_active="$(systemctl is-active codex-status-telemetry.service 2>/dev/null || echo not-found)"
unit_present=false
if systemctl list-unit-files codex-status-telemetry.timer --no-legend 2>/dev/null | grep -q 'codex-status-telemetry.timer'; then
  unit_present=true
fi

latest_present="$(present_file "$latest")"
send_present="$(present_file "$send_latest")"
capture_present="$(present_file "$capture")"
manual=false
if [ "$collector_present" = "true" ] && { [ "$send_present" = "true" ] || [ "$latest_present" = "true" ]; }; then
  manual=true
fi

print old_chain_dirs_present "$old_dirs"
print codex_status_collector_present "$collector_present"
print telemetry_codex_status_present "$telemetry_present"
print systemd_timer_unit_present "$unit_present"
print systemd_timer_active "$timer_active"
print systemd_timer_enabled "$timer_enabled"
print service_active "$service_active"
print latest_json_present "$latest_present"
print latest_json_mtime "$(mtime_file "$latest")"
print send_latest_present "$send_present"
print capture_script_present "$capture_present"
print manual_fallback_possible "$manual"
print secret_markers_printed false
'@

$remoteCommand = "bash -lc $(ConvertTo-ShellSingleQuoted $script)"
ssh $SshHost $remoteCommand
if ($LASTEXITCODE -ne 0) {
  throw "Old Codex status safe diagnostic failed with exit code $LASTEXITCODE"
}
