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

foreach ($command in @("ssh", "scp")) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $command"
  }
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

json_probe() {
  label="$1"
  file="$2"
  if [ ! -f "$file" ]; then
    print_check "${label}_file_exists" false
    print_check "${label}_mtime" missing
    print_check "${label}_marker_present" false
    return
  fi
  print_check "${label}_file_exists" true
  print_check "${label}_mtime" "$(stat -c '%Y' "$file" 2>/dev/null || echo unknown)"
  if grep -qi 'auth\.json' "$file" 2>/dev/null; then
    print_check "${label}_marker_present" true
  else
    print_check "${label}_marker_present" false
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$label" "$file" <<'PY'
import json
import sys

label = sys.argv[1]
path = sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    def kind(value):
        if value is None:
            return "null"
        if isinstance(value, bool):
            return "boolean"
        if isinstance(value, (int, float)):
            return "number"
        if isinstance(value, str):
            return "string"
        if isinstance(value, list):
            return "array"
        if isinstance(value, dict):
            return "object"
        return "unknown"
    print(f"{label}_type={kind(data)}")
    if isinstance(data, dict):
        for key in ("type", "status", "limits", "limits_detail", "collectors", "outputs"):
            print(f"{label}_{key}_key_present={str(key in data).lower()}")
        limits = data.get("limits")
        details = data.get("limits_detail")
        print(f"{label}_limits_count={len(limits) if isinstance(limits, list) else 0}")
        print(f"{label}_limits_detail_count={len(details) if isinstance(details, list) else 0}")
except Exception as exc:
    print(f"{label}_type=unreadable")
PY
  else
    print_check "${label}_type" unknown
  fi
}

project_dir="$(expand_path "$PROJECT_DIR")"
print_check project_dir_exists "$([ -d "$project_dir" ] && echo true || echo false)"

if [ -d "$project_dir" ]; then
  cd "$project_dir" || exit 0
  print_check env_file_exists "$([ -f .env ] && echo true || echo false)"
  print_check deploy_env_file_exists "$([ -f deploy/lax/.env ] && echo true || echo false)"
  print_check state_dir_exists "$([ -d state ] && echo true || echo false)"
  print_check logs_dir_exists "$([ -d logs ] && echo true || echo false)"
  print_check spool_count "$(find state/spool -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

  json_probe usage state/codex-usage-latest.safe.snapshot.json
  json_probe health state/agent-health-latest.safe.snapshot.json
  json_probe state state/agent-state.json

  if curl -fsS http://127.0.0.1:18081/healthz >/tmp/jerry-telemetry-agent-diag-healthz.json 2>/tmp/jerry-telemetry-agent-diag-healthz.err; then
    print_check healthz_18081_ok true
    if grep -qi 'auth\.json' /tmp/jerry-telemetry-agent-diag-healthz.json 2>/dev/null; then
      print_check healthz_18081_marker_present true
    else
      print_check healthz_18081_marker_present false
    fi
  else
    print_check healthz_18081_ok false
    print_check healthz_18081_marker_present false
  fi
fi

print_check raw_backend_printed false
print_check auth_json_printed false
'@

$localScript = Join-Path ([IO.Path]::GetTempPath()) ("diag-lax-agent-safe-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remotePath = "/tmp/diag-lax-agent-safe-$([Guid]::NewGuid().ToString("N")).sh"
try {
  [IO.File]::WriteAllText($localScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  scp $localScript "${SshHost}:$remotePath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy safe diagnostic script to LAX."
  }

  $remoteCommand = "PROJECT_DIR=$(ConvertTo-ShellSingleQuoted $ProjectDir) bash $(ConvertTo-ShellSingleQuoted $remotePath); rc=`$?; rm -f $(ConvertTo-ShellSingleQuoted $remotePath); exit `$rc"
  ssh $SshHost $remoteCommand
  if ($LASTEXITCODE -ne 0) {
    throw "LAX safe diagnostics failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $localScript -ErrorAction SilentlyContinue
}
