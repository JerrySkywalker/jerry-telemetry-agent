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
