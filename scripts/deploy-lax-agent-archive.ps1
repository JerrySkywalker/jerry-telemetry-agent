param(
  [string]$SshHost = "lax",
  [string]$ProjectDir = "~/jerry-telemetry-agent",
  [string]$Ref = "main",
  [switch]$ConfirmDeploy
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function ConvertTo-ShellSingleQuoted {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + ($Value -replace "'", "'\''") + "'"
}

foreach ($command in @("git", "ssh", "scp")) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $command"
  }
}

$archive = Join-Path ([IO.Path]::GetTempPath()) ("jerry-telemetry-agent-" + [Guid]::NewGuid().ToString("N") + ".tar")
$remoteArchive = "/tmp/jerry-telemetry-agent-$([Guid]::NewGuid().ToString("N")).tar"
$confirmValue = if ($ConfirmDeploy) { "1" } else { "0" }

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

copy_if_exists() {
  src="$1"
  dst="$2"
  if [ -e "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

project_dir="$(expand_path "$PROJECT_DIR")"
parent_dir="$(dirname "$project_dir")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_path="${project_dir}.bak.${stamp}"
next_dir="${project_dir}.next.${stamp}"

if [ "$CONFIRM_DEPLOY" != "1" ]; then
  echo "backup_path=dry_run"
  echo "compose_config_ok=false"
  echo "agent_healthz_18081_ok=false"
  echo "raw_backend_printed=false"
  echo "auth_json_printed=false"
  exit 0
fi

mkdir -p "$parent_dir" "$next_dir"
tar -xf "$REMOTE_ARCHIVE" -C "$next_dir"

if [ -d "$project_dir" ]; then
  cp -a "$project_dir" "$backup_path"
  copy_if_exists "$project_dir/.env" "$next_dir/.env"
  for file in "$project_dir"/.env.*; do
    [ -e "$file" ] || continue
    copy_if_exists "$file" "$next_dir/$(basename "$file")"
  done
  copy_if_exists "$project_dir/logs" "$next_dir/logs"
  copy_if_exists "$project_dir/state" "$next_dir/state"
  for env_file in "$project_dir"/deploy/*/.env; do
    [ -e "$env_file" ] || continue
    rel="${env_file#"$project_dir"/}"
    copy_if_exists "$env_file" "$next_dir/$rel"
  done
  for state_dir in "$project_dir"/deploy/*/state; do
    [ -e "$state_dir" ] || continue
    rel="${state_dir#"$project_dir"/}"
    copy_if_exists "$state_dir" "$next_dir/$rel"
  done
else
  backup_path="none"
  mkdir -p "$next_dir/state" "$next_dir/logs"
fi

find "$next_dir" -type f \( -name '.env' -o -name '.env.*' \) -exec chmod 600 {} \; 2>/dev/null || true

rm -rf "${project_dir}.previous"
if [ -d "$project_dir" ]; then
  mv "$project_dir" "${project_dir}.previous"
fi
mv "$next_dir" "$project_dir"

cd "$project_dir"
export HEALTH_HOST_PORT="${HEALTH_HOST_PORT:-18081}"
compose() {
  docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example "$@"
}

compose_config_ok=false
if compose config >/tmp/jerry-telemetry-agent-compose-config.out 2>/tmp/jerry-telemetry-agent-compose-config.err; then
  compose_config_ok=true
fi

if [ "$compose_config_ok" = "true" ]; then
  compose build >/tmp/jerry-telemetry-agent-compose-build.out 2>/tmp/jerry-telemetry-agent-compose-build.err
  compose up -d >/tmp/jerry-telemetry-agent-compose-up.out 2>/tmp/jerry-telemetry-agent-compose-up.err
fi

agent_healthz_18081_ok=false
for _ in 1 2 3 4 5; do
  if curl -fsS http://127.0.0.1:18081/healthz >/tmp/jerry-telemetry-agent-healthz.out 2>/tmp/jerry-telemetry-agent-healthz.err; then
    agent_healthz_18081_ok=true
    break
  fi
  sleep 2
done

echo "backup_path=$backup_path"
echo "compose_config_ok=$compose_config_ok"
echo "agent_healthz_18081_ok=$agent_healthz_18081_ok"
echo "raw_backend_printed=false"
echo "auth_json_printed=false"
'@

$localScript = Join-Path ([IO.Path]::GetTempPath()) ("deploy-lax-agent-archive-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remoteScriptPath = "/tmp/deploy-lax-agent-archive-$([Guid]::NewGuid().ToString("N")).sh"

try {
  git archive --format=tar --output=$archive $Ref
  if ($LASTEXITCODE -ne 0) {
    throw "git archive failed for ref $Ref"
  }

  [IO.File]::WriteAllText($localScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  scp $archive "${SshHost}:$remoteArchive" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy archive to LAX."
  }
  scp $localScript "${SshHost}:$remoteScriptPath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy deploy script to LAX."
  }

  $remoteCommand = "PROJECT_DIR=$(ConvertTo-ShellSingleQuoted $ProjectDir) REMOTE_ARCHIVE=$(ConvertTo-ShellSingleQuoted $remoteArchive) CONFIRM_DEPLOY=$(ConvertTo-ShellSingleQuoted $confirmValue) bash $(ConvertTo-ShellSingleQuoted $remoteScriptPath); rc=`$?; rm -f $(ConvertTo-ShellSingleQuoted $remoteArchive) $(ConvertTo-ShellSingleQuoted $remoteScriptPath); exit `$rc"
  ssh $SshHost $remoteCommand
  if ($LASTEXITCODE -ne 0) {
    throw "LAX archive deploy failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $archive -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $localScript -ErrorAction SilentlyContinue
}
