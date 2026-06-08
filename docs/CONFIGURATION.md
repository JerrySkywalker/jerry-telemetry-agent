# Configuration

Configuration is read from environment variables and CLI flags.

Required for upload:
- `TELEMETRY_HUB_URL`
- `TELEMETRY_NODE_ID`
- `TELEMETRY_NODE_SECRET`

Runtime:
- `AGENT_MODE=daemon|once`
- `AGENT_INTERVAL_SECONDS=600`
- `CODEX_PROVIDER=file|host-codex|container-codex`
- `STATE_PATH=/state/agent-state.json`
- `SPOOL_DIR=/state/spool`
- `FORCE_SEND=false`

Health:
- `HEALTH_SERVER_ENABLED=true`
- `HEALTH_HOST=0.0.0.0`
- `HEALTH_PORT=8081`
