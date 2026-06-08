# jerry-telemetry-agent

Dockerized node-side telemetry agent for Jerry telemetry hub.

## Quick Start

```powershell
npm install
npm run typecheck
npm test
npm run build
docker compose config
```

For local dry-run file mode:

```powershell
$env:CODEX_STATUS_LATEST_PATH="fixtures/latest.json"
npm run dev -- --once --dry-run --provider file
```

Do not put real telemetry secrets in git. The agent never logs `TELEMETRY_NODE_SECRET`.
