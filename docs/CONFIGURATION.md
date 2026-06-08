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
- `CODEX_HOME=~/.codex`
- `CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage`
- `CODEX_PROVIDER=file|host-codex|container-codex`
- `STATE_PATH=/state/agent-state.json`
- `SPOOL_DIR=/state/spool`
- `FORCE_SEND=false`
- `TELEMETRY_NODE_ID`
- `TELEMETRY_NODE_ROLE`
- `TELEMETRY_ACCOUNT_LABEL`

Health:
- `HEALTH_SERVER_ENABLED=true`
- `HEALTH_HOST=0.0.0.0`
- `HEALTH_PORT=8081`

Fallback:
- `CODEX_STATUS_LATEST_PATH=/input/latest.json`
- `HOST_CODEX_BIN=/host-bin/codex`
- `HOST_CODEX_HOME=/host-codex-home`
- `CODEX_TMUX_SESSION=codex-status-agent`
