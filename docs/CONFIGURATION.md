# Configuration

Configuration is read from environment variables, CLI flags, and optionally a declarative per-node JSON file. Environment variables and CLI flags remain supported for the LAX migration path.

Required only for HTTP upload:
- `TELEMETRY_HUB_URL`
- `TELEMETRY_NODE_ID`
- `TELEMETRY_NODE_SECRET`

Each node must use a unique `TELEMETRY_NODE_ID` and a unique `TELEMETRY_NODE_SECRET`. The secret is supplied outside git and is used only for HMAC upload signing.

Runtime:
- `AGENT_MODE=daemon|once`
- `CODEX_USAGE_POLL_INTERVAL_SECONDS=300`
- `AGENT_INTERVAL_SECONDS=600` legacy fallback for poll interval
- `TELEMETRY_COLLECTOR_MODE=codex-backend-usage|codex-cli-status-fallback`
- `TELEMETRY_NODE_CONFIG_PATH=/config/node.json`
- `TELEMETRY_ENABLE_TMUX_FALLBACK=false`
- `TELEMETRY_OUTPUT_MODE=stdout,file,http`
- `TELEMETRY_OUTPUT_FILE=/state/codex-usage-latest.safe.snapshot.json`
- `CODEX_USAGE_LATEST_PATH=/state/codex-usage-latest.safe.snapshot.json`
- `CODEX_USAGE_LAST_GOOD_PATH=/state/codex-usage-last-good.safe.snapshot.json`
- `CODEX_HOME=~/.codex` on Unix-like hosts, `%USERPROFILE%\.codex` on Windows
- `CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage`
- `CODEX_PROVIDER=backend-usage|file|host-codex|container-codex`
- `STATE_PATH=/state/agent-state.json`
- `SPOOL_DIR=/state/spool`
- `FORCE_SEND=false`
- `TELEMETRY_NODE_ID`
- `TELEMETRY_NODE_ROLE`
- `TELEMETRY_ACCOUNT_LABEL`

Health:
- `HEALTH_SERVER_ENABLED=true`
- `HEALTH_HOST=0.0.0.0`
- `HEALTH_PORT=8081` controls the container listener port.
- `HEALTH_HOST_PORT=18081` controls the localhost host port in Docker Compose.

Fallback:
- `CODEX_STATUS_LATEST_PATH=/input/latest.json`
- `HOST_CODEX_BIN=/host-bin/codex`
- `HOST_CODEX_HOME=/host-codex-home`
- `CODEX_TMUX_SESSION=codex-status-agent`

## Command Examples

Backend usage once, stdout only, no upload:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_NODE_ID="local-dev"
$env:TELEMETRY_OUTPUT_MODE="stdout"
$env:HEALTH_SERVER_ENABLED="false"
npm run dev -- --once --collector codex-backend-usage
```

Backend usage once, safe file only, no upload:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_OUTPUT_MODE="file"
$env:TELEMETRY_OUTPUT_FILE=".smoke/codex-usage-latest.safe.snapshot.json"
$env:HEALTH_SERVER_ENABLED="false"
npm run dev -- --once --collector codex-backend-usage
```

HTTP upload is enabled only when `TELEMETRY_OUTPUT_MODE` includes `http` and all upload settings are present.

`codex-backend-usage` is the primary collector. `codex-cli-status-fallback` and tmux `/status` capture are migration fallbacks only and remain disabled by default.

## Declarative Node Config

`TELEMETRY_NODE_CONFIG_PATH` may point at a JSON file with node identity and allowlisted collectors:

```json
{
  "node_id": "us-lax-pro-01",
  "hostname": "novix-lax-01",
  "region": "us-lax",
  "role": "codex-node",
  "collectors": [
    { "name": "codex-backend-usage", "enabled": true, "interval_seconds": 300 },
    { "name": "agent-health", "enabled": true, "interval_seconds": 300 }
  ]
}
```

Allowed collector names are `codex-backend-usage`, `codex-cli-status-fallback`, and `agent-health`. Unknown names fail closed at startup. Collector-specific configuration is typed by the registry; arbitrary shell command collectors are intentionally not supported.

For a non-LAX pilot that does not collect Codex usage, enable only `agent-health`:

```json
{
  "node_id": "example-node-01",
  "hostname": "example-node-01",
  "region": "example-region",
  "role": "general-node",
  "collectors": [
    { "name": "agent-health", "enabled": true, "interval_seconds": 300 }
  ]
}
```

The checked-in examples are:
- `deploy/examples/non-lax-agent-health.node.json`
- `deploy/examples/non-lax-pilot.env.example`

The example env keeps `TELEMETRY_OUTPUT_MODE=file` so the pilot runs locally without production upload. It includes `TELEMETRY_HUB_URL=https://telemetry.jerryskywalker.space/v1/events` for the future approved upload path, but HTTP output must not be enabled until a real node secret is manually supplied outside git.

Env and CLI compatibility rules:
- `--collector` overrides `TELEMETRY_COLLECTOR_MODE`.
- `TELEMETRY_COLLECTOR_MODE` overrides the first enabled usage collector in the node config.
- `TELEMETRY_NODE_ID`, `TELEMETRY_HOSTNAME`, `TELEMETRY_REGION`, and `TELEMETRY_NODE_ROLE` override the matching node config fields.
- If no node config is provided, the default usage collector remains `codex-backend-usage`.

The LAX production target remains:
- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HOSTNAME=novix-lax-01`
- `TELEMETRY_REGION=us-lax`
- `TELEMETRY_OUTPUT_MODE=file,http`

For Docker backend usage mode, mount the host Codex auth directory read-only and set `CODEX_HOME` to that mount. The image must not include `auth.json`; the host only needs Docker and an installed/authenticated Codex CLI.
