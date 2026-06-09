param(
  [string]$SshHost = "lax",
  [string]$ProjectDir = "~/jerry-telemetry-agent",
  [int]$Tail = 100,
  [switch]$Follow
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function ConvertTo-ShellSingleQuoted {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + ($Value -replace "'", "'\''") + "'"
}

if ($Tail -lt 1) {
  throw "-Tail must be greater than zero."
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  throw "Required command not found: ssh"
}
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
  throw "Required command not found: scp"
}

$followValue = if ($Follow) { "1" } else { "0" }
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

echo "reminder=Do not paste logs if they unexpectedly contain secrets or token-shaped values."

if [ "$FOLLOW_LOGS" = "1" ]; then
  docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml logs --tail "$TAIL_LINES" --follow
else
  docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml logs --tail "$TAIL_LINES"
fi
'@

$localScript = Join-Path ([IO.Path]::GetTempPath()) ("lax-agent-logs-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remotePath = "/tmp/lax-agent-logs-$([Guid]::NewGuid().ToString("N")).sh"
try {
  [IO.File]::WriteAllText($localScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  scp $localScript "${SshHost}:$remotePath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy log script to LAX."
  }

  $remoteCommand = "PROJECT_DIR=$(ConvertTo-ShellSingleQuoted $ProjectDir) TAIL_LINES=$(ConvertTo-ShellSingleQuoted ([string]$Tail)) FOLLOW_LOGS=$(ConvertTo-ShellSingleQuoted $followValue) bash $(ConvertTo-ShellSingleQuoted $remotePath); rc=`$?; rm -f $(ConvertTo-ShellSingleQuoted $remotePath); exit `$rc"
  ssh $SshHost $remoteCommand
  if ($LASTEXITCODE -ne 0) {
    throw "LAX log command failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $localScript -ErrorAction SilentlyContinue
}
