param(
  [string]$SshHost = "lax",
  [string]$ProjectDir = "~/jerry-telemetry-agent",
  [switch]$Confirm
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

$confirmValue = if ($Confirm) { "1" } else { "0" }
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
compose_cmd='docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml restart'

echo "project_dir=$project_dir"
echo "restart_command=$compose_cmd"
echo "rebuild=false"
echo "down_up=false"

if [ "$CONFIRM_RESTART" != "1" ]; then
  echo "dry_run=true"
  echo "confirm_to_execute=rerun with -Confirm"
else
  cd "$project_dir"
  docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml restart
  echo "dry_run=false"
  echo "restart_executed=true"
fi
'@

$localScript = Join-Path ([IO.Path]::GetTempPath()) ("lax-agent-restart-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remotePath = "/tmp/lax-agent-restart-$([Guid]::NewGuid().ToString("N")).sh"
try {
  [IO.File]::WriteAllText($localScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  scp $localScript "${SshHost}:$remotePath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy restart script to LAX."
  }

  $remoteCommand = "PROJECT_DIR=$(ConvertTo-ShellSingleQuoted $ProjectDir) CONFIRM_RESTART=$(ConvertTo-ShellSingleQuoted $confirmValue) bash $(ConvertTo-ShellSingleQuoted $remotePath); rc=`$?; rm -f $(ConvertTo-ShellSingleQuoted $remotePath); exit `$rc"
  ssh $SshHost $remoteCommand
  if ($LASTEXITCODE -ne 0) {
    throw "LAX restart command failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $localScript -ErrorAction SilentlyContinue
}
