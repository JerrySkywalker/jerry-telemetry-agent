# LAX Backend Usage Docker Migration

This is preparation and operations documentation. Do not stop the current systemd timer, change production hub settings, or add production secrets without explicit manual approval.

## Target

- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HOSTNAME=novix-lax-01`
- `TELEMETRY_REGION=us-lax`
- `TELEMETRY_COLLECTOR=codex-backend-usage`
- `CODEX_PROVIDER=backend-usage`
- `CODEX_HOME=/host-codex-home`
- `CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage`

Backend usage is the primary migration path. Host prerequisites are only Docker plus an installed/authenticated Codex CLI. The container must mount `/home/ubuntu/.codex:/host-codex-home:ro`; it must not bake Codex auth into the image.

The existing LAX production timer remains unchanged until explicit manual approval. Do not stop, disable, or replace it during preflight, dry-run, or once-upload work.

## Migration State

Completed phases:

- Local backend usage smoke.
- LAX Docker dry-run.
- LAX real once upload.
- LAX Docker daemon canary.
- LAX daemon operations hardening.
- LAX canary observation report.

Current phase:

- Primary runtime declared.

Pending phases:

- 24-hour and 72-hour continued observation.
- Optional old fallback archival under a separate approved cleanup goal.
- Dashboard / Glance integration.

Current primary runtime:

- Docker backend usage daemon emitting `codex.usage.snapshot`.
- Same daemon emitting `telemetry.agent.health` for push-based monitor health.

Old tmux/status chain:

- `codex-status-telemetry.timer` is expected to remain `inactive/disabled`.
- Old collector and sender files are retained.
- Old chain is manual fallback only.
- Do not re-enable old timer without explicit manual approval.

All daemon Compose operations must use `--env-file .env`. `.env` and `.env.bak.*` are secret files; keep them mode `600`, never print them, and never commit them.

## Preflight

```powershell
scripts/lax-backend-usage-preflight.ps1
```

The preflight checks SSH, Docker, Docker Compose, host Codex, host `~/.codex/auth.json`, whether the auth file contains `tokens.access_token`, `codex-status-telemetry.timer` status, hub `/healthz`, latest hub endpoints, disk, memory, and whether `~/jerry-telemetry-agent` exists. It prints only redacted status and never prints token values.

## Compose Template

Use:

- [deploy/lax/docker-compose.yml.example](../deploy/lax/docker-compose.yml.example)
- [deploy/lax/.env.example](../deploy/lax/.env.example)
- [deploy/lax/README.md](../deploy/lax/README.md)

The template mounts:

- `/home/ubuntu/.codex:/host-codex-home:ro`
- `./state:/state`

The health endpoint is bound only to localhost:

```text
127.0.0.1:18081:8081
```

`HEALTH_PORT` is the container listener port and should normally stay `8081`. `HEALTH_HOST_PORT` is the LAX localhost port and defaults to `18081`.

`TELEMETRY_OUTPUT_MODE=file,http` is documented for one-shot upload validation and final migration. Use `stdout,file` only for initial dry-run validation.

## Safe Docker Dry-Run

Run from a committed branch:

```powershell
scripts/lax-agent-dry-run.ps1
```

The script copies the current committed tree to:

```text
~/jerry-telemetry-agent
```

It then creates a non-secret `.env`, creates `state/`, writes a dry-run Compose override, runs:

```bash
docker compose -f deploy/lax/docker-compose.yml.example -f docker-compose.dry-run.yml config
docker compose -f deploy/lax/docker-compose.yml.example -f docker-compose.dry-run.yml run --build --rm jerry-telemetry-agent node dist/src/main.js --once --collector codex-backend-usage
```

Dry-run settings:

- `AGENT_MODE=once`
- `TELEMETRY_OUTPUT_MODE=stdout,file`
- `TELEMETRY_HUB_URL=` blank
- `TELEMETRY_NODE_SECRET=` blank
- `HEALTH_SERVER_ENABLED=false`
- `FORCE_SEND=true`

Expected success diagnostics:

- `docker_compose_config=ok`
- `docker_compose_run_once=ok`
- `status_ok=true`
- `limits_count` greater than zero
- Backend completeness checks should prefer `limits_detail[]` window rows when present: `default:5h`, `default:weekly`, `additional:GPT-5.3-Codex-Spark:5h`, and `additional:GPT-5.3-Codex-Spark:weekly`.
- `http_upload=disabled`
- `daemon_enabled=false`

The script validates the safe snapshot file on LAX and fails if it contains forbidden token or raw identity markers.

## Real Once Upload

Run this only after the no-upload Docker dry-run succeeds. This performs one production HTTP upload from the Dockerized backend usage collector.

The script requires an explicit production switch:

```powershell
scripts/lax-agent-real-once-upload.ps1 -ConfirmProductionUpload
```

The script sources the existing old sender env on LAX, maps `TELEMETRY_SECRET` to `TELEMETRY_NODE_SECRET` in-process, and never prints the secret value.

Once-upload settings:

- `AGENT_MODE=once`
- `CODEX_PROVIDER=backend-usage`
- `TELEMETRY_COLLECTOR=codex-backend-usage`
- `TELEMETRY_OUTPUT_MODE=http,file`
- `TELEMETRY_HUB_URL=https://telemetry.jerryskywalker.space/v1/events`
- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HOSTNAME=novix-lax-01`
- `TELEMETRY_REGION=us-lax`
- `FORCE_SEND=true`
- `HEALTH_SERVER_ENABLED=false`

Expected success diagnostics:

- `docker_compose_config=ok`
- `docker_compose_run_once=ok`
- `snapshot_status_ok=true`
- `snapshot_limits_count` greater than zero
- Required backend-derived window rows are present before upload: default 5h, default weekly, Spark 5h, and Spark weekly.
- `snapshot_node_id=us-lax-pro-01`
- `http_upload=attempted_once`
- `daemon_enabled=false`

This is a one-shot upload test only. It must not stop, disable, or modify `codex-status-telemetry.timer`.

Confirm the old timer state before and after:

```bash
systemctl status codex-status-telemetry.timer --no-pager
```

Verify the hub received `codex.usage.snapshot`:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
```

Verify node latest:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/nodes/us-lax-pro-01/latest
```

Verify the old chain still has a latest `codex.status` event:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.status
```

Do not run `docker compose up -d`, do not enable daemon mode, and do not install any new systemd unit during this real-once test.

## Real Once Result

Goal 007 performed one Dockerized backend usage upload on LAX.

Hub comparison after upload:

- New backend chain: `event_type=codex.usage.snapshot`, `node_id=us-lax-pro-01`, `collector=codex-backend-usage`, `status.ok=true`, `limits_count=2`, latest event id `17`, received at `2026-06-08T18:06:14.718Z`.
- Old status chain: `event_type=codex.status`, `node_id=us-lax-pro-01`, `collector=codex-status-collector`, latest event id `16`, received at `2026-06-08T09:29:33.484Z`.
- Node latest now points at the new `codex.usage.snapshot` event.

No daemon mode was enabled, no production hub settings were changed, and no old sender files were deleted.

## Daemon Canary

Goal 008 enabled the Dockerized backend usage collector as a controlled daemon canary. Goal 009 hardened observation and operations around the already-running canary. Goal 010 recorded canary observation and primary-runtime readiness. Goal 011 declares the Docker backend usage daemon as the current primary runtime and freezes the old tmux/status chain as manual fallback only.

Current canary state:

- LAX Docker daemon canary is running.
- The Docker backend usage daemon is the current primary Codex usage telemetry runtime.
- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HOSTNAME=novix-lax-01`
- `TELEMETRY_COLLECTOR=codex-backend-usage`
- `TELEMETRY_OUTPUT_MODE=file,http`

This LAX profile is one declarative collector profile for the multi-node agent. It remains compatible with env-only configuration; a future node may instead set `TELEMETRY_NODE_CONFIG_PATH` to a JSON file with node identity and allowlisted collectors. Unknown collector names fail closed, and shell-command collectors are not supported.
- `CODEX_USAGE_POLL_INTERVAL_SECONDS=300`
- Health is exposed only on LAX localhost: `127.0.0.1:18081->8081`.
- The old `codex-status-telemetry.timer` should remain `disabled` and `inactive`.
- Old tmux/status files are retained as manual fallback only.

All LAX daemon Compose operations must pass the persisted env file explicitly:

```bash
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml ps
```

This prevents `TELEMETRY_NODE_SECRET` unset warnings when Compose renders `docker-compose.daemon.yml`.

The LAX files `.env` and `.env.bak.*` are secret files:

- Do not print their contents.
- Do not copy them into the repository.
- Do not commit them.
- Keep mode `600`.
- Status tooling may report existence, non-empty secret status, counts, and permission summaries only.

Start the daemon from the local repository:

```powershell
scripts/lax-agent-daemon-canary.ps1 -ConfirmProductionDaemonCanary
```

The script copies the committed tree to:

```text
~/jerry-telemetry-agent
```

It creates or refreshes:

- `~/jerry-telemetry-agent/state`
- `~/jerry-telemetry-agent/logs`
- non-secret host `.env` files at `.env` and `deploy/lax/.env`
- host-only `docker-compose.daemon.yml`

The script sources the existing old sender env on LAX, maps `TELEMETRY_SECRET` to `TELEMETRY_NODE_SECRET` only inside the remote shell environment, and never writes the secret to the rendered `.env` files.

Daemon settings:

- `restart: unless-stopped`
- `AGENT_MODE=daemon`
- `TELEMETRY_OUTPUT_MODE=file,http`
- `TELEMETRY_HUB_URL=https://telemetry.jerryskywalker.space/v1/events`
- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HOSTNAME=novix-lax-01`
- `TELEMETRY_REGION=us-lax`
- `TELEMETRY_COLLECTOR=codex-backend-usage`
- `CODEX_PROVIDER=backend-usage`
- `CODEX_HOME=/host-codex-home`
- `CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage`
- `CODEX_USAGE_POLL_INTERVAL_SECONDS=300`
- `HEALTH_SERVER_ENABLED=true`
- `HEALTH_HOST=0.0.0.0`
- `HEALTH_PORT=8081`
- `HEALTH_HOST_PORT=18081`

Required mounts:

```yaml
volumes:
  - /home/ubuntu/.codex:/host-codex-home:ro
  - ../../state:/state
```

The container health port is exposed only on LAX localhost:

```yaml
ports:
  - "127.0.0.1:18081:8081"
```

Manual start command on LAX:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml up -d --build
```

View daemon state:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml ps
```

View logs:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml logs --tail 100
```

Check health from LAX only:

```bash
curl -fsS http://127.0.0.1:18081/healthz
```

Inspect the latest safe snapshot through the health endpoint when possible:

```bash
curl -fsS http://127.0.0.1:18081/api/codex/usage/summary
```

If host reads of `state/codex-usage-latest.safe.snapshot.json` fail with `PermissionError`, do not treat that as daemon failure. Prefer health endpoints or `docker exec` reads of the safe snapshot. Do not widen `/home/ubuntu/.codex` permissions.

Container fallback:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml exec jerry-telemetry-agent node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync("/state/codex-usage-latest.safe.snapshot.json","utf8")); console.log(JSON.stringify({type:s.type,node_id:s.node?.id,status_ok:s.status?.ok,limits_count:s.limits?.length,observed_at:s.observed_at}, null, 2));'
```

Verify hub latest:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/telemetry.agent.health
curl -fsS https://telemetry.jerryskywalker.space/v1/nodes/us-lax-pro-01/latest
```

Observe two poll cycles:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
sleep 310
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
```

Compare `id`, `received_at`, payload `observed_at`, and `payload.status.ok`. `id`, `received_at`, and `observed_at` should advance when the backend usage payload changes or `FORCE_SEND=true` is used for a one-shot validation. During normal daemon operation, unchanged payloads may update the local safe snapshot without uploading a duplicate event.

Stop the daemon:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml stop
```

Rollback the canary:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml down
```

The old `codex-status-telemetry.timer` remains untouched. Do not stop, enable, disable, modify, or automatically restore it as part of daemon canary operations. Old sender and collector files remain only as a manual fallback and should not be deleted by canary scripts.

Operational helpers:

```powershell
scripts/diag-lax-agent-safe.ps1
scripts/lax-agent-status.ps1
scripts/lax-agent-logs.ps1 -Tail 100
scripts/lax-agent-restart.ps1
scripts/lax-agent-rollback.ps1
```

Hotfix archive deployment:

```powershell
scripts/deploy-lax-agent-archive.ps1 -ConfirmDeploy
```

Use this only after the hotfix is merged to `main`. It deploys by local `git archive` plus `scp`, preserves `.env`, `.env.*`, `logs/`, `state/`, `deploy/*/.env`, and `deploy/*/state/`, and builds through Docker. It does not run npm on LAX and prints only safe status keys.

## Daemon Canary Result

Goal 008 started the Dockerized backend usage daemon on LAX with the `jerry-telemetry-agent` Compose project.

Initial daemon verification:

- `docker compose up -d --build` succeeded.
- Compose service state was `Up` with `127.0.0.1:18081->8081/tcp`.
- `curl http://127.0.0.1:18081/healthz` succeeded from LAX.
- `state/codex-usage-latest.safe.snapshot.json` existed.
- Snapshot `status.ok=true`.
- Snapshot `limits_count=2`.
- Log and state marker scan found no token or raw identity markers.
- Hub latest `codex.usage.snapshot` advanced to event id `20`, received at `2026-06-09T08:17:49.145Z`, observed at `2026-06-09T08:17:48.475Z`.

Two-cycle observation:

- After at least two 300 second daemon poll intervals, hub latest advanced to event id `22`.
- Event `22` was received at `2026-06-09T08:27:50.891Z`.
- Event `22` was observed at `2026-06-09T08:27:50.332Z`.
- `status.ok` remained `true`.
- `limits_count` remained `2`.
- Node latest also pointed at event id `22`.

The old `codex-status-telemetry.timer` remained `disabled` and `inactive`.

## Dry-Run / Once Rollback / No-Op

There is nothing to roll back after the dry-run or once-upload because no daemon, timer, or systemd unit is enabled. Leave the old `codex.status` chain as-is.

If temporary Docker resources remain after an interrupted run:

```bash
cd ~/jerry-telemetry-agent
docker compose -p jerry-telemetry-agent-dry-run -f deploy/lax/docker-compose.yml.example -f docker-compose.dry-run.yml down --remove-orphans
docker compose -p jerry-telemetry-agent-real-once -f deploy/lax/docker-compose.yml.example -f docker-compose.real-once.yml down --remove-orphans
```

## Safe Local Commands

Local Windows smoke, no upload:

```powershell
scripts/smoke-codex-backend-usage-local.ps1
```

Equivalent npm command:

```powershell
npm run smoke:codex-backend
npm run smoke:agent-health
```

Backend once, stdout only, no upload:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_NODE_ID="local-dev"
$env:TELEMETRY_OUTPUT_MODE="stdout"
$env:HEALTH_SERVER_ENABLED="false"
npm run dev -- --once --collector codex-backend-usage
```

Backend once, file only, no upload:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_OUTPUT_MODE="file"
$env:TELEMETRY_OUTPUT_FILE=".smoke/codex-usage-latest.safe.snapshot.json"
$env:HEALTH_SERVER_ENABLED="false"
npm run dev -- --once --collector codex-backend-usage
```
