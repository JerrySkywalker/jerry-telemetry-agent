param(
  [string]$SshHost = "lax",
  [string]$RemoteDir = "~/jerry-telemetry-agent",
  [string]$OldSenderEnv = "~/jerry-telemetry-codex-status/send-latest.env",
  [string]$NodeId = "us-lax-pro-01",
  [string]$Hostname = "novix-lax-01",
  [string]$Region = "us-lax",
  [string]$HubUrl = "https://telemetry.jerryskywalker.space/v1/events",
  [int]$PollIntervalSeconds = 300,
  [switch]$ConfirmProductionDaemonCanary
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $ConfirmProductionDaemonCanary) {
  throw "Refusing production daemon canary without -ConfirmProductionDaemonCanary."
}

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
$archive = Join-Path ([IO.Path]::GetTempPath()) ("jerry-telemetry-agent-daemon-" + [Guid]::NewGuid().ToString("N") + ".tar")
$localRemoteScript = Join-Path ([IO.Path]::GetTempPath()) ("jerry-telemetry-agent-daemon-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remoteArchive = "/tmp/jerry-telemetry-agent-daemon.tar"
$remoteScriptPath = "/tmp/jerry-telemetry-agent-daemon-canary.sh"

$remoteScript = @'
set -eu

print_check() {
  name="$1"
  value="$2"
  printf '%s=%s\n' "$name" "$value"
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

remote_dir="$(expand_path "$REMOTE_DIR")"
old_sender_env="$(expand_path "$OLD_SENDER_ENV")"

mkdir -p "$remote_dir/state/spool" "$remote_dir/logs"
tar -xf "$REMOTE_ARCHIVE" -C "$remote_dir"
cd "$remote_dir"

if [ ! -f "$old_sender_env" ]; then
  echo "Old sender env is missing." >&2
  exit 1
fi

set -a
. "$old_sender_env"
set +a

if [ -z "${TELEMETRY_SECRET:-}" ]; then
  echo "TELEMETRY_SECRET is missing in old sender env." >&2
  exit 1
fi

export TELEMETRY_NODE_SECRET="$TELEMETRY_SECRET"
export AGENT_MODE=daemon
export CODEX_PROVIDER=backend-usage
export TELEMETRY_COLLECTOR=codex-backend-usage
export TELEMETRY_COLLECTOR_MODE=codex-backend-usage
export CODEX_HOME=/host-codex-home
export CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage
export CODEX_USAGE_POLL_INTERVAL_SECONDS="$POLL_INTERVAL_SECONDS"
export TELEMETRY_OUTPUT_MODE=file,http
export TELEMETRY_HUB_URL="$HUB_URL"
export TELEMETRY_NODE_ID="$NODE_ID"
export TELEMETRY_HOSTNAME="$HOSTNAME_VALUE"
export TELEMETRY_REGION="$REGION"
export TELEMETRY_OUTPUT_FILE=/state/codex-usage-latest.safe.snapshot.json
export CODEX_USAGE_LATEST_PATH=/state/codex-usage-latest.safe.snapshot.json
export CODEX_USAGE_LAST_GOOD_PATH=/state/codex-usage-last-good.safe.snapshot.json
export STATE_PATH=/state/agent-state.json
export SPOOL_DIR=/state/spool
export HEALTH_SERVER_ENABLED=true
export HEALTH_HOST=0.0.0.0
export HEALTH_PORT=8081
export TELEMETRY_ENABLE_TMUX_FALLBACK=false
export FORCE_SEND=false

if docker compose version >/dev/null 2>&1; then
  compose() {
    docker compose -p jerry-telemetry-agent "$@"
  }
elif command -v docker-compose >/dev/null 2>&1; then
  compose() {
    docker-compose -p jerry-telemetry-agent "$@"
  }
else
  echo "Docker Compose is missing." >&2
  exit 1
fi

cat > .env <<ENV
AGENT_MODE=daemon
CODEX_USAGE_POLL_INTERVAL_SECONDS=$POLL_INTERVAL_SECONDS
TELEMETRY_COLLECTOR=codex-backend-usage
TELEMETRY_COLLECTOR_MODE=codex-backend-usage
CODEX_PROVIDER=backend-usage
CODEX_HOME=/host-codex-home
CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage
TELEMETRY_OUTPUT_MODE=file,http
TELEMETRY_OUTPUT_FILE=/state/codex-usage-latest.safe.snapshot.json
CODEX_USAGE_LATEST_PATH=/state/codex-usage-latest.safe.snapshot.json
CODEX_USAGE_LAST_GOOD_PATH=/state/codex-usage-last-good.safe.snapshot.json
STATE_PATH=/state/agent-state.json
SPOOL_DIR=/state/spool
HEALTH_SERVER_ENABLED=true
HEALTH_HOST=0.0.0.0
HEALTH_PORT=8081
TELEMETRY_HUB_URL=$HUB_URL
TELEMETRY_NODE_ID=$NODE_ID
TELEMETRY_HOSTNAME=$HOSTNAME_VALUE
TELEMETRY_REGION=$REGION
TELEMETRY_ENABLE_TMUX_FALLBACK=false
FORCE_SEND=false
ENV
cp .env deploy/lax/.env

cat > docker-compose.daemon.yml <<'YAML'
services:
  jerry-telemetry-agent:
    build:
      context: ../..
      dockerfile: Dockerfile
    image: jerry-telemetry-agent:latest
    restart: unless-stopped
    environment:
      AGENT_MODE: daemon
      CODEX_USAGE_POLL_INTERVAL_SECONDS: ${CODEX_USAGE_POLL_INTERVAL_SECONDS}
      TELEMETRY_COLLECTOR: codex-backend-usage
      TELEMETRY_COLLECTOR_MODE: codex-backend-usage
      CODEX_PROVIDER: backend-usage
      CODEX_HOME: /host-codex-home
      CODEX_USAGE_ENDPOINT: https://chatgpt.com/backend-api/wham/usage
      TELEMETRY_OUTPUT_MODE: file,http
      TELEMETRY_HUB_URL: ${TELEMETRY_HUB_URL}
      TELEMETRY_NODE_ID: ${TELEMETRY_NODE_ID}
      TELEMETRY_NODE_SECRET: ${TELEMETRY_NODE_SECRET}
      TELEMETRY_HOSTNAME: ${TELEMETRY_HOSTNAME}
      TELEMETRY_REGION: ${TELEMETRY_REGION}
      TELEMETRY_OUTPUT_FILE: /state/codex-usage-latest.safe.snapshot.json
      CODEX_USAGE_LATEST_PATH: /state/codex-usage-latest.safe.snapshot.json
      CODEX_USAGE_LAST_GOOD_PATH: /state/codex-usage-last-good.safe.snapshot.json
      STATE_PATH: /state/agent-state.json
      SPOOL_DIR: /state/spool
      HEALTH_SERVER_ENABLED: "true"
      HEALTH_HOST: 0.0.0.0
      HEALTH_PORT: "8081"
      TELEMETRY_ENABLE_TMUX_FALLBACK: "false"
      FORCE_SEND: "false"
    volumes:
      - /home/ubuntu/.codex:/host-codex-home:ro
      - ../../state:/state
    ports:
      - "127.0.0.1:18081:8081"
YAML

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml config >/tmp/jerry-telemetry-agent-daemon-config.txt
print_check docker_compose_config ok

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml up -d --build
print_check docker_compose_up ok

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml ps

sleep 10
curl -fsS http://127.0.0.1:18081/healthz >/tmp/jerry-telemetry-agent-healthz.json
print_check healthz ok

snapshot="state/codex-usage-latest.safe.snapshot.json"
if [ ! -f "$snapshot" ]; then
  echo "snapshot not written: $snapshot" >&2
  exit 1
fi

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml run -T --rm --no-deps -e EXPECTED_NODE_ID="$NODE_ID" --entrypoint node jerry-telemetry-agent - <<'NODE'
const fs = require("fs");
const snapshotPath = "/state/codex-usage-latest.safe.snapshot.json";
const files = [
  snapshotPath,
  "/state/codex-usage-last-good.safe.snapshot.json",
  "/state/agent-state.json"
].filter((file) => fs.existsSync(file));
const forbidden = ["access_token", "refresh_token", "TELEMETRY_NODE_SECRET", "TELEMETRY_SECRET", "account_id", "user_id", "email", "referral_beacon", "promo"];
for (const file of files) {
  const text = fs.readFileSync(file, "utf8");
  for (const marker of forbidden) {
    if (text.includes(marker)) {
      throw new Error(`${file} contains forbidden marker: ${marker}`);
    }
  }
}
const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
if (snapshot.type !== "codex.usage.snapshot") throw new Error("snapshot type mismatch");
if (!snapshot.status || snapshot.status.ok !== true) throw new Error("snapshot status.ok is not true");
if (!Array.isArray(snapshot.limits) || snapshot.limits.length <= 0) throw new Error("snapshot limits_count is not greater than zero");
if (!snapshot.node || snapshot.node.id !== process.env.EXPECTED_NODE_ID) throw new Error("snapshot node_id mismatch");
console.log(`snapshot_status_ok=${snapshot.status.ok}`);
console.log(`snapshot_limits_count=${snapshot.limits.length}`);
console.log(`snapshot_observed_at=${snapshot.observed_at}`);
NODE

logs="$(compose -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml logs --tail 100 2>&1)"
printf '%s\n' "$logs" >/tmp/jerry-telemetry-agent-daemon-tail.log
if printf '%s\n' "$logs" | grep -E 'access_token|refresh_token|TELEMETRY_NODE_SECRET|TELEMETRY_SECRET|account_id|user_id|referral_beacon|promo' >/dev/null; then
  echo "daemon logs contain a forbidden marker" >&2
  exit 1
fi
print_check logs_tail_100_checked ok

curl -fsS "$HUB_URL/latest/codex.usage.snapshot" >state/hub-latest-event.json
curl -fsS "${HUB_URL%/events}/nodes/$NODE_ID/latest" >state/hub-node-latest.json
compose -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml run -T --rm --no-deps --entrypoint node jerry-telemetry-agent - <<'NODE'
const fs = require("fs");
const latest = JSON.parse(fs.readFileSync("/state/hub-latest-event.json", "utf8"));
const nodeLatest = JSON.parse(fs.readFileSync("/state/hub-node-latest.json", "utf8"));
const latestEvent = latest.events?.[0] ?? latest.event ?? latest;
const latestPayload = latestEvent.envelope?.payload ?? latest.payload ?? latestEvent.payload ?? {};
const nodeEvent = nodeLatest.events?.[0] ?? nodeLatest.event ?? nodeLatest;
console.log(`hub_latest_event_id=${latestEvent.id ?? ""}`);
console.log(`hub_latest_received_at=${latestEvent.received_at ?? ""}`);
console.log(`hub_latest_observed_at=${latestEvent.captured_at ?? latestPayload.observed_at ?? ""}`);
console.log(`hub_latest_status_ok=${latestPayload.status?.ok ?? ""}`);
console.log(`hub_latest_limits_count=${Array.isArray(latestPayload.limits) ? latestPayload.limits.length : ""}`);
console.log(`node_latest_event_id=${nodeEvent.id ?? ""}`);
NODE
print_check daemon_state running
print_check rollback "cd $remote_dir && docker compose -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml down"
'@

try {
  Push-Location $repoRoot
  Assert-Command "git"
  Assert-Command "ssh"
  Assert-Command "scp"

  Invoke-Native "archive_repo_head" {
    git archive --format=tar -o $archive HEAD
  }

  Invoke-Native "copy_archive_to_lax" {
    scp $archive "${SshHost}:$remoteArchive"
  }

  [IO.File]::WriteAllText($localRemoteScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
  Invoke-Native "copy_remote_daemon_script" {
    scp $localRemoteScript "${SshHost}:$remoteScriptPath"
  }

  $remoteCommand = "REMOTE_DIR=$(ConvertTo-ShellSingleQuoted $RemoteDir) OLD_SENDER_ENV=$(ConvertTo-ShellSingleQuoted $OldSenderEnv) REMOTE_ARCHIVE=$(ConvertTo-ShellSingleQuoted $remoteArchive) NODE_ID=$(ConvertTo-ShellSingleQuoted $NodeId) HOSTNAME_VALUE=$(ConvertTo-ShellSingleQuoted $Hostname) REGION=$(ConvertTo-ShellSingleQuoted $Region) HUB_URL=$(ConvertTo-ShellSingleQuoted $HubUrl) POLL_INTERVAL_SECONDS=$(ConvertTo-ShellSingleQuoted ([string]$PollIntervalSeconds)) bash $(ConvertTo-ShellSingleQuoted $remoteScriptPath)"
  Invoke-Native "run_lax_daemon_canary" {
    ssh $SshHost $remoteCommand
  }
} finally {
  Pop-Location
  Remove-Item -LiteralPath $archive -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $localRemoteScript -ErrorAction SilentlyContinue
}
