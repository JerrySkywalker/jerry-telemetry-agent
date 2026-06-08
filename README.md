# jerry-telemetry-agent

Dockerized node-side telemetry agent for Jerry telemetry hub.

Primary Codex collection now reads local Codex `auth.json`, uses the ChatGPT-managed access token to call `https://chatgpt.com/backend-api/wham/usage`, normalizes the response into `codex.usage.snapshot`, and emits it through stdout, file, or HTTP sinks. The tmux `/status` collector is fallback only.

## Quick Start

```powershell
npm install
npm run typecheck
npm test
npm run build
docker compose config
```

For local backend usage stdout mode:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_NODE_ID="local-dev"
npm run dev -- --once
```

For migration fallback file mode:

```powershell
$env:CODEX_STATUS_LATEST_PATH="fixtures/latest.json"
npm run dev -- --once --collector codex-cli-status-fallback --provider file
```

Do not put real telemetry secrets in git. The agent never logs `TELEMETRY_NODE_SECRET`, access tokens, refresh tokens, raw `auth.json`, or raw backend usage responses.
