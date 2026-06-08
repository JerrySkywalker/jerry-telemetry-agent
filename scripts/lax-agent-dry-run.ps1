param(
  [string]$SshHost = "lax",
  [string]$RemoteDir = "~/jerry-telemetry-agent",
  [string]$NodeId = "us-lax-pro-01",
  [string]$Hostname = "novix-lax-01",
  [string]$Region = "us-lax"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Description,

    [Parameter(Mandatory = $true)]
    [scriptblock]$Action
  )

  Write-Host "step=$Description"
  $global:LASTEXITCODE = 0
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "Step failed: $Description exited with code $LASTEXITCODE"
  }
}

function Assert-Command {
  param([Parameter(Mandatory = $true)][string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function ConvertTo-ShellSingleQuoted {
  param([Parameter(Mandatory = $true)][string]$Value)

  return "'" + ($Value -replace "'", "'\''") + "'"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$archive = Join-Path ([IO.Path]::GetTempPath()) ("jerry-telemetry-agent-" + [Guid]::NewGuid().ToString("N") + ".tar")
$localRemoteScript = Join-Path ([IO.Path]::GetTempPath()) ("jerry-telemetry-agent-dry-run-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remoteArchive = "/tmp/jerry-telemetry-agent-dry-run.tar"
$remoteScriptPath = "/tmp/jerry-telemetry-agent-dry-run.sh"
$prereqScript = @'
set -eu
command -v docker >/dev/null
if docker compose version >/dev/null 2>&1; then
  exit 0
fi
command -v docker-compose >/dev/null
'@
$encodedPrereqScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($prereqScript -replace "`r`n", "`n")))

Push-Location $repoRoot
try {
  Assert-Command "git"
  Assert-Command "ssh"
  Assert-Command "scp"

  $branch = (git branch --show-current).Trim()
  $commit = (git rev-parse --short HEAD).Trim()
  Write-Host "branch=$branch"
  Write-Host "commit=$commit"
  Write-Host "remote_dir=$RemoteDir"

  Invoke-Native "check_lax_docker_prereqs" {
    ssh $SshHost "bash -lc 'set -o pipefail; echo $encodedPrereqScript | base64 -d | bash'"
  }

  Invoke-Native "archive_repo_head" {
    git archive --format=tar -o $archive HEAD
  }

  Invoke-Native "copy_archive_to_lax" {
    scp $archive "${SshHost}:$remoteArchive"
  }

  $remoteScript = @'
set -eu

print_check() {
  name="$1"
  value="$2"
  printf '%s=%s\n' "$name" "$value"
}

if [ "$REMOTE_DIR" = "~" ]; then
  remote_dir="$HOME"
elif [ "${REMOTE_DIR#\~/}" != "$REMOTE_DIR" ]; then
  remote_dir="$HOME/${REMOTE_DIR#\~/}"
else
  remote_dir="$REMOTE_DIR"
fi
mkdir -p "$remote_dir"
tar -xf "$REMOTE_ARCHIVE" -C "$remote_dir"
cd "$remote_dir"
mkdir -p state/spool

if [ ! -f deploy/lax/docker-compose.yml.example ]; then
  echo "missing deploy/lax/docker-compose.yml.example" >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  compose() {
    docker compose -p jerry-telemetry-agent-dry-run "$@"
  }
elif command -v docker-compose >/dev/null 2>&1; then
  compose() {
    docker-compose -p jerry-telemetry-agent-dry-run "$@"
  }
else
  echo "Docker Compose is missing." >&2
  exit 1
fi
trap 'compose -f deploy/lax/docker-compose.yml.example -f docker-compose.dry-run.yml down --remove-orphans >/dev/null 2>&1 || true' EXIT

cat > .env <<ENV
AGENT_MODE=once
CODEX_USAGE_POLL_INTERVAL_SECONDS=300
TELEMETRY_COLLECTOR=codex-backend-usage
TELEMETRY_COLLECTOR_MODE=codex-backend-usage
CODEX_PROVIDER=backend-usage
CODEX_HOME=/host-codex-home
CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage
TELEMETRY_OUTPUT_MODE=stdout,file
TELEMETRY_OUTPUT_FILE=/state/codex-usage-latest.safe.snapshot.json
CODEX_USAGE_LATEST_PATH=/state/codex-usage-latest.safe.snapshot.json
CODEX_USAGE_LAST_GOOD_PATH=/state/codex-usage-last-good.safe.snapshot.json
STATE_PATH=/state/agent-state.json
SPOOL_DIR=/state/spool
HEALTH_SERVER_ENABLED=false
HEALTH_PORT=8081
TELEMETRY_HUB_URL=
TELEMETRY_NODE_ID=$NODE_ID
TELEMETRY_HOSTNAME=$HOSTNAME_VALUE
TELEMETRY_REGION=$REGION
TELEMETRY_ENABLE_TMUX_FALLBACK=false
FORCE_SEND=true
ENV
cp .env deploy/lax/.env

cat > docker-compose.dry-run.yml <<'YAML'
services:
  jerry-telemetry-agent:
    build:
      context: ../..
      dockerfile: Dockerfile
    restart: "no"
    ports: []
    environment:
      AGENT_MODE: once
      TELEMETRY_OUTPUT_MODE: stdout,file
      TELEMETRY_HUB_URL: ""
      TELEMETRY_NODE_SECRET: ""
      HEALTH_SERVER_ENABLED: "false"
      FORCE_SEND: "true"
    volumes:
      - /home/ubuntu/.codex:/host-codex-home:ro
      - ../../state:/state
YAML

print_check env_file ".env created"
print_check state_dir "present"
if [ -d /home/ubuntu/.codex ]; then
  print_check codex_auth_mount_source "present"
else
  print_check codex_auth_mount_source "missing"
fi

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.dry-run.yml config >/tmp/jerry-telemetry-agent-compose-config.txt
print_check docker_compose_config "ok"

rm -f state/codex-usage-latest.safe.snapshot.json
compose -f deploy/lax/docker-compose.yml.example -f docker-compose.dry-run.yml run -T --build --rm jerry-telemetry-agent node dist/src/main.js --once --collector codex-backend-usage >/tmp/jerry-telemetry-agent-dry-run.stdout
print_check docker_compose_run_once "ok"

snapshot="state/codex-usage-latest.safe.snapshot.json"
if [ ! -f "$snapshot" ]; then
  echo "snapshot not written: $snapshot" >&2
  exit 1
fi

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.dry-run.yml run -T --rm --no-deps -e EXPECTED_NODE_ID="$NODE_ID" --entrypoint node jerry-telemetry-agent - <<'NODE'
const fs = require("fs");
const snapshotPath = "/state/codex-usage-latest.safe.snapshot.json";
const text = fs.readFileSync(snapshotPath, "utf8");
const forbidden = ["access_token", "refresh_token", "email", "account_id", "user_id", "referral_beacon", "promo"];
for (const marker of forbidden) {
  if (text.includes(marker)) {
    throw new Error(`snapshot contains forbidden marker: ${marker}`);
  }
}
const snapshot = JSON.parse(text);
if (snapshot.type !== "codex.usage.snapshot") throw new Error("snapshot type mismatch");
if (!snapshot.status || snapshot.status.ok !== true) throw new Error("snapshot status.ok is not true");
if (!Array.isArray(snapshot.limits)) throw new Error("snapshot limits is not an array");
if (snapshot.limits.length <= 0) throw new Error("snapshot limits_count is not greater than zero");
if (!snapshot.node || snapshot.node.id !== process.env.EXPECTED_NODE_ID) throw new Error("snapshot node_id mismatch");
console.log("snapshot_path=state/codex-usage-latest.safe.snapshot.json");
console.log(`status_ok=${snapshot.status.ok}`);
console.log(`limits_count=${snapshot.limits.length}`);
console.log(`node_id=${snapshot.node.id}`);
console.log(`observed_at=${snapshot.observed_at}`);
NODE

print_check http_upload "disabled"
print_check daemon_enabled "false"
'@

  [IO.File]::WriteAllText($localRemoteScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  Invoke-Native "copy_remote_dry_run_script" {
    scp $localRemoteScript "${SshHost}:$remoteScriptPath"
  }

  $remoteCommand = "REMOTE_DIR=$(ConvertTo-ShellSingleQuoted $RemoteDir) REMOTE_ARCHIVE=$(ConvertTo-ShellSingleQuoted $remoteArchive) NODE_ID=$(ConvertTo-ShellSingleQuoted $NodeId) HOSTNAME_VALUE=$(ConvertTo-ShellSingleQuoted $Hostname) REGION=$(ConvertTo-ShellSingleQuoted $Region) bash $(ConvertTo-ShellSingleQuoted $remoteScriptPath)"
  Invoke-Native "run_lax_docker_dry_run" {
    ssh $SshHost $remoteCommand
  }
} finally {
  Pop-Location
  Remove-Item -LiteralPath $archive -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $localRemoteScript -ErrorAction SilentlyContinue
}
