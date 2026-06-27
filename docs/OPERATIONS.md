# Operations

Do not paste secrets, token-shaped values, raw `auth.json`, raw backend responses, `.env`, or `.env.bak.*` contents into issues, PRs, docs, or chat.

Spooled events live under `SPOOL_DIR` and are retried before newly captured payloads.

## Local One-Shot Batch Testing

This workflow is for local Windows and fixture validation before server deployment. It does not deploy, SSH, start or stop services, alter LAX runtime, or modify the production Hub.

Fixture file-only:

```powershell
.\scripts\agent-once.ps1 -Mode Fixture -Output FileOnly -NodeId local-win-dev-01 -OutFile .smoke\fixture.batch.safe.json
```

Local Windows file-only:

```powershell
.\scripts\agent-once.ps1 -Mode LocalWindows -Output FileOnly -NodeId local-win-dev-01 -OutFile .smoke\local.batch.safe.json
```

Local smoke:

```powershell
.\scripts\smoke-local-agent.ps1
```

Fixture push to an already-running local Hub:

```powershell
.\scripts\agent-once.ps1 -Mode Fixture -Output Push -HubUrl http://127.0.0.1:3000 -NodeId sample-node -WriteSecret <dev-secret> -ReadToken <dev-read-token>
```

Push mode posts a safe batch to `/v1/events/batch`. With a read token it verifies readback from `/v1/nodes`, `/v1/summary`, `/v1/services`, and `/v1/custom`, and prints only concise status fields. If Hub is not running or dev credentials are absent, `scripts/smoke-local-agent-e2e.ps1` reports a safe failure or skip.

## Non-LAX Pilot Package

The first non-LAX pilot package is local-only and health-only:

- Node profile: `example-node-01`, `example-region`, `general-node`.
- Node config: `deploy/examples/non-lax-agent-health.node.json`.
- Env example: `deploy/examples/non-lax-pilot.env.example`.
- Local smoke: `npm run build` then `npm run smoke:non-lax-pilot`.

The smoke loads the example node config, runs once with `TELEMETRY_OUTPUT_MODE=file`, writes `telemetry.agent.health`, builds a local envelope for verification, and prints only booleans, counts, and safe status fields. It does not upload to the hub.

## Future Target-Node Preflight

A future read-only target-node preflight should check only:

- Docker availability.
- Docker Compose availability.
- Disk free space and memory summary.
- Ability to reach `https://telemetry.jerryskywalker.space/healthz`.
- Local state directory existence and write permissions.
- Absence of conflicting existing telemetry agent services or timers.

The preflight must not print secrets, `.env`, tokens, Authorization headers, cookies, raw backend responses, account IDs, user IDs, or emails. It must not create services, edit timers, run `docker compose up`, deploy, or upload telemetry.

## Current Primary Runtime

- Primary runtime: Docker backend usage daemon.
- Event type: `codex.usage.snapshot`.
- Agent health event type: `telemetry.agent.health`.
- Node: `us-lax-pro-01`.
- Hostname: `novix-lax-01`.
- Local health: `http://127.0.0.1:18081/healthz` from LAX only.
- Remote monitor health source: telemetry hub latest `telemetry.agent.health`.
- Daily status command: `scripts/lax-agent-status.ps1`.
- Agent health status command: `scripts/lax-agent-health-status.ps1`.
- Logs command: `scripts/lax-agent-logs.ps1 -Tail 50`.
- Canary report command: `scripts/lax-agent-canary-report.ps1`.
- Rollback dry-run: `scripts/lax-agent-rollback.ps1`.
- Rollback confirmed: `scripts/lax-agent-rollback.ps1 -Confirm`.
- Old fallback: `codex-status-telemetry.timer` remains `inactive/disabled`; do not modify it without explicit manual approval.
- Old fallback status: `scripts/lax-old-fallback-status.ps1`.

See [PRIMARY_RUNTIME.md](PRIMARY_RUNTIME.md) for the current runtime declaration and fallback rules.

## LAX Daemon Canary

Status:

```powershell
scripts/lax-agent-status.ps1
```

Logs:

```powershell
scripts/lax-agent-logs.ps1 -Tail 50
```

Compact canary report:

```powershell
scripts/lax-agent-canary-report.ps1
```

Restart dry-run:

```powershell
scripts/lax-agent-restart.ps1
```

Confirmed restart:

```powershell
scripts/lax-agent-restart.ps1 -Confirm
```

Restart uses `docker compose restart`; it does not rebuild and does not run `down/up`.

Rollback dry-run:

```powershell
scripts/lax-agent-rollback.ps1
```

Confirmed rollback:

```powershell
scripts/lax-agent-rollback.ps1 -Confirm
```

Rollback only runs:

```bash
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml down
```

It does not delete `state/`, `.env`, `.env.bak.*`, old sender files, or old collector files. It does not enable the old systemd timer and does not modify the telemetry hub.

Hub latest check:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/telemetry.agent.health
curl -fsS https://telemetry.jerryskywalker.space/v1/nodes/us-lax-pro-01/latest
```

Local health check from LAX only:

```bash
curl -fsS http://127.0.0.1:18081/healthz
curl -fsS http://127.0.0.1:18081/api/agent/health/latest
curl -fsS http://127.0.0.1:18081/api/codex/usage/summary
```

Guarded one-shot health upload:

```powershell
scripts/lax-agent-health-once.ps1 -ConfirmProductionUpload
```

This sends through the existing HMAC HTTP sink and must not print `.env`, node secrets, Codex tokens, or raw backend responses.

All LAX daemon Compose commands must use:

```bash
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml ...
```

This keeps `TELEMETRY_NODE_SECRET` interpolation explicit and avoids unset warnings.

LAX `state/` files may be owned by the container user. Prefer health endpoints or `docker exec` safe-summary reads. If permissions ever need adjustment, adjust only `~/jerry-telemetry-agent/state`; never widen `/home/ubuntu/.codex` permissions.

`.env` and `.env.bak.*` are secret files. Scripts may report existence, non-empty secret status, counts, and permission summaries, but must not print contents. Prefer `chmod 600 .env .env.bak.*`.

## LAX Backend Usage Dry-Run

Preflight only, no production changes:

```powershell
scripts/lax-backend-usage-preflight.ps1
```

Docker dry-run on LAX, no HTTP upload and no daemon:

```powershell
scripts/lax-agent-dry-run.ps1
```

The dry-run copies the current committed tree to `~/jerry-telemetry-agent`, creates a non-secret `.env`, mounts `/home/ubuntu/.codex:/host-codex-home:ro`, runs `docker compose config`, and runs the agent once with `TELEMETRY_OUTPUT_MODE=stdout,file`.

Do not stop or modify `codex-status-telemetry.timer` during preflight or dry-run. Do not run `docker compose up -d` for backend usage until daemon migration is explicitly approved.

## LAX Real-Once Upload

The real-once upload is a guarded one-shot command, not an enabled service:

```powershell
scripts/lax-agent-real-once-upload.ps1 -ConfirmProductionUpload
```

It uses:

- `event_type=codex.usage.snapshot`
- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HUB_URL=https://telemetry.jerryskywalker.space/v1/events`
- `TELEMETRY_OUTPUT_MODE=http,file`
- `AGENT_MODE=once`
- `FORCE_SEND=true`

The script reads the existing old sender secret from LAX and maps it in-process for the Docker container. It must not print the secret.

Verify after the one-shot run:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
curl -fsS https://telemetry.jerryskywalker.space/v1/nodes/us-lax-pro-01/latest
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.status
```

Compare the latest events:

- `codex.usage.snapshot` should have `source.collector=codex-backend-usage`, `payload.status.ok=true`, and `payload.limits` populated.
- `codex.status` should remain available from `source.collector=codex-status-collector`.
- `/v1/nodes/us-lax-pro-01/latest` should show the newest event for the node.

The existing `codex.status` timer must remain unchanged throughout the test. Do not run `docker compose up -d`.

Rollback/no-op: no daemon is enabled by dry-run or once-upload, so there is no runtime service to roll back. If an interrupted run leaves temporary Compose resources:

```bash
cd ~/jerry-telemetry-agent
docker compose -p jerry-telemetry-agent-dry-run -f deploy/lax/docker-compose.yml.example -f docker-compose.dry-run.yml down --remove-orphans
docker compose -p jerry-telemetry-agent-real-once -f deploy/lax/docker-compose.yml.example -f docker-compose.real-once.yml down --remove-orphans
```
