param(
  [string]$SshHost = "lax",
  [string]$ProjectDir = "~/jerry-telemetry-agent",
  [switch]$ConfirmProductionUpload
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $ConfirmProductionUpload) {
  throw "Refusing production upload without -ConfirmProductionUpload."
}

function ConvertTo-ShellSingleQuoted {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + ($Value -replace "'", "'\''") + "'"
}

$remoteScript = @'
set -eu

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
cd "$project_dir"

compose() {
  docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml "$@"
}

compose config >/dev/null
compose run -T --rm \
  -e AGENT_MODE=once \
  -e FORCE_SEND=true \
  -e TELEMETRY_AGENT_HEALTH_ENABLED=true \
  jerry-telemetry-agent node dist/src/main.js --once --health --collector codex-backend-usage >/tmp/jerry-telemetry-agent-health-once.out

if grep -Eqi 'token|secret|authorization|auth.json' /tmp/jerry-telemetry-agent-health-once.out 2>/dev/null; then
  echo "health_once_output_secret_scan=failed"
  exit 1
fi

echo "health_once_upload=attempted"
echo "health_once_output_secret_scan=ok"
'@

$localScript = Join-Path ([IO.Path]::GetTempPath()) ("lax-agent-health-once-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remotePath = "/tmp/lax-agent-health-once-$([Guid]::NewGuid().ToString("N")).sh"
try {
  [IO.File]::WriteAllText($localScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  scp $localScript "${SshHost}:$remotePath" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to copy health once script to LAX." }

  $remoteCommand = "PROJECT_DIR=$(ConvertTo-ShellSingleQuoted $ProjectDir) bash $(ConvertTo-ShellSingleQuoted $remotePath); rc=`$?; rm -f $(ConvertTo-ShellSingleQuoted $remotePath); exit `$rc"
  ssh $SshHost $remoteCommand
  if ($LASTEXITCODE -ne 0) { throw "LAX health once failed with exit code $LASTEXITCODE" }
} finally {
  Remove-Item -LiteralPath $localScript -ErrorAction SilentlyContinue
}
