param(
  [string]$SshHost = "lax",
  [string]$ProjectDir = "~/jerry-telemetry-agent"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function ConvertTo-ShellSingleQuoted {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + ($Value -replace "'", "'\''") + "'"
}

$remoteScript = @'
set -u

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

project_dir="$(expand_path "$PROJECT_DIR")"
cd "$project_dir" || exit 1

if curl -fsS http://127.0.0.1:18081/api/agent/health/latest >/tmp/jerry-agent-health-latest.json 2>/dev/null; then
  python3 - <<'PY'
import json
with open("/tmp/jerry-agent-health-latest.json", "r", encoding="utf-8") as handle:
    health = json.load(handle)
collector = (health.get("collectors") or [{}])[0]
outputs = health.get("outputs") or {}
print(f"event_type={health.get('type', '')}")
print(f"node_id={(health.get('node') or {}).get('id', '')}")
print(f"status_ok={(health.get('status') or {}).get('ok', '')}")
print(f"observed_at={health.get('observed_at', '')}")
print(f"pending_spool_count={outputs.get('pending_spool_count', '')}")
print(f"latest_limits_count={collector.get('latest_limits_count', '')}")
PY
else
  echo "agent_health_latest_available=false"
fi
'@

$localScript = Join-Path ([IO.Path]::GetTempPath()) ("lax-agent-health-status-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remotePath = "/tmp/lax-agent-health-status-$([Guid]::NewGuid().ToString("N")).sh"
try {
  [IO.File]::WriteAllText($localScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  scp $localScript "${SshHost}:$remotePath" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to copy health status script to LAX." }

  $remoteCommand = "PROJECT_DIR=$(ConvertTo-ShellSingleQuoted $ProjectDir) bash $(ConvertTo-ShellSingleQuoted $remotePath); rc=`$?; rm -f $(ConvertTo-ShellSingleQuoted $remotePath); exit `$rc"
  ssh $SshHost $remoteCommand
  if ($LASTEXITCODE -ne 0) { throw "LAX health status failed with exit code $LASTEXITCODE" }
} finally {
  Remove-Item -LiteralPath $localScript -ErrorAction SilentlyContinue
}
