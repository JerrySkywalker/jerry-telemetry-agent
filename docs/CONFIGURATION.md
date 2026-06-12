# Configuration

Configuration is read from environment variables and CLI flags.

Required only for HTTP upload:
- `TELEMETRY_HUB_URL`
- `TELEMETRY_NODE_ID`
- `TELEMETRY_NODE_SECRET`

Runtime:
- `AGENT_MODE=daemon|once`
- `CODEX_USAGE_POLL_INTERVAL_SECONDS=300`
- `AGENT_INTERVAL_SECONDS=600` legacy fallback for poll interval
- `TELEMETRY_COLLECTOR_MODE=codex-backend-usage|codex-cli-status-fallback`
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

For Docker backend usage mode, mount the host Codex auth directory read-only and set `CODEX_HOME` to that mount. The image must not include `auth.json`; the host only needs Docker and an installed/authenticated Codex CLI.
