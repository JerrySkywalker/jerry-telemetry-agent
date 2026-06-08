# Operations

Useful commands:

```bash
docker compose config
docker compose build
docker compose up -d
curl http://127.0.0.1:8081/healthz
curl http://127.0.0.1:8081/status
```

Spooled events live under `SPOOL_DIR` and are retried before newly captured payloads.

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

The real-once upload is a manual test plan, not an enabled service. It uses:

- `event_type=codex.usage.snapshot`
- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HUB_URL=https://telemetry.jerryskywalker.space/v1/events`
- `TELEMETRY_OUTPUT_MODE=file,http`

Verify after the one-shot run:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
```

The existing `codex.status` timer must remain active throughout the test.
