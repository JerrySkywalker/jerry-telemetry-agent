param(
  [string]$SshHost = "lax",
  [string]$RemoteDir = "~/jerry-telemetry-agent",
  [string]$OldSenderEnv = "~/jerry-telemetry-codex-status/send-latest.env",
  [string]$NodeId = "us-lax-pro-01",
  [string]$Hostname = "novix-lax-01",
  [string]$Region = "us-lax",
  [string]$HubUrl = "https://telemetry.jerryskywalker.space/v1/events",
  [switch]$ConfirmProductionUpload
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $ConfirmProductionUpload) {
  throw "Refusing production upload without -ConfirmProductionUpload."
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

$localRemoteScript = Join-Path ([IO.Path]::GetTempPath()) ("jerry-telemetry-agent-real-once-" + [Guid]::NewGuid().ToString("N") + ".sh")
$remoteScriptPath = "/tmp/jerry-telemetry-agent-real-once.sh"

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
export AGENT_MODE=once
export CODEX_PROVIDER=backend-usage
export TELEMETRY_COLLECTOR=codex-backend-usage
export TELEMETRY_COLLECTOR_MODE=codex-backend-usage
export CODEX_HOME=/host-codex-home
export CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage
export TELEMETRY_OUTPUT_MODE=http,file
export TELEMETRY_HUB_URL="$HUB_URL"
export TELEMETRY_NODE_ID="$NODE_ID"
export TELEMETRY_HOSTNAME="$HOSTNAME_VALUE"
export TELEMETRY_REGION="$REGION"
export TELEMETRY_OUTPUT_FILE=/state/codex-usage-latest.safe.snapshot.json
export CODEX_USAGE_LATEST_PATH=/state/codex-usage-latest.safe.snapshot.json
export CODEX_USAGE_LAST_GOOD_PATH=/state/codex-usage-last-good.safe.snapshot.json
export STATE_PATH=/state/agent-state.json
export SPOOL_DIR=/state/spool
export HEALTH_SERVER_ENABLED=false
export FORCE_SEND=true
export TELEMETRY_ENABLE_TMUX_FALLBACK=false

if docker compose version >/dev/null 2>&1; then
  compose() {
    docker compose -p jerry-telemetry-agent-real-once "$@"
  }
elif command -v docker-compose >/dev/null 2>&1; then
  compose() {
    docker-compose -p jerry-telemetry-agent-real-once "$@"
  }
else
  echo "Docker Compose is missing." >&2
  exit 1
fi
trap 'compose -f deploy/lax/docker-compose.yml.example -f docker-compose.real-once.yml down --remove-orphans >/dev/null 2>&1 || true' EXIT

cat > docker-compose.real-once.yml <<'YAML'
services:
  jerry-telemetry-agent:
    build:
      context: ../..
      dockerfile: Dockerfile
    restart: "no"
    ports: []
    environment:
      AGENT_MODE: once
      CODEX_PROVIDER: backend-usage
      TELEMETRY_COLLECTOR: codex-backend-usage
      TELEMETRY_COLLECTOR_MODE: codex-backend-usage
      CODEX_HOME: /host-codex-home
      CODEX_USAGE_ENDPOINT: https://chatgpt.com/backend-api/wham/usage
      TELEMETRY_OUTPUT_MODE: http,file
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
      HEALTH_SERVER_ENABLED: "false"
      FORCE_SEND: "true"
      TELEMETRY_ENABLE_TMUX_FALLBACK: "false"
    volumes:
      - /home/ubuntu/.codex:/host-codex-home:ro
      - ../../state:/state
YAML

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.real-once.yml config >/dev/null
print_check docker_compose_config ok

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.real-once.yml run -T --build --rm jerry-telemetry-agent node dist/src/main.js --once --collector codex-backend-usage >/tmp/jerry-telemetry-agent-real-once.stdout
print_check docker_compose_run_once ok

compose -f deploy/lax/docker-compose.yml.example -f docker-compose.real-once.yml run -T --rm --no-deps -e EXPECTED_NODE_ID="$NODE_ID" --entrypoint node jerry-telemetry-agent - <<'NODE'
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
if (!Array.isArray(snapshot.limits) || snapshot.limits.length <= 0) throw new Error("snapshot limits_count is not greater than zero");
if (!snapshot.node || snapshot.node.id !== process.env.EXPECTED_NODE_ID) throw new Error("snapshot node_id mismatch");
console.log(`snapshot_status_ok=${snapshot.status.ok}`);
console.log(`snapshot_limits_count=${snapshot.limits.length}`);
console.log(`snapshot_node_id=${snapshot.node.id}`);
console.log(`snapshot_observed_at=${snapshot.observed_at}`);
NODE

print_check http_upload attempted_once
print_check daemon_enabled false
'@

try {
  Assert-Command "ssh"
  Assert-Command "scp"

  [IO.File]::WriteAllText($localRemoteScript, ($remoteScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))

  Invoke-Native "copy_remote_real_once_script" {
    scp $localRemoteScript "${SshHost}:$remoteScriptPath"
  }

  $remoteCommand = "REMOTE_DIR=$(ConvertTo-ShellSingleQuoted $RemoteDir) OLD_SENDER_ENV=$(ConvertTo-ShellSingleQuoted $OldSenderEnv) NODE_ID=$(ConvertTo-ShellSingleQuoted $NodeId) HOSTNAME_VALUE=$(ConvertTo-ShellSingleQuoted $Hostname) REGION=$(ConvertTo-ShellSingleQuoted $Region) HUB_URL=$(ConvertTo-ShellSingleQuoted $HubUrl) bash $(ConvertTo-ShellSingleQuoted $remoteScriptPath)"
  Invoke-Native "run_lax_real_once_upload" {
    ssh $SshHost $remoteCommand
  }
} finally {
  Remove-Item -LiteralPath $localRemoteScript -ErrorAction SilentlyContinue
}
