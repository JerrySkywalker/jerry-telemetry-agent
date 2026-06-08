# LAX Backend Usage Docker Migration

This is preparation documentation only. Do not deploy to LAX, stop the current systemd timer, change production hub settings, or add production secrets without explicit manual approval.

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

## Rollback / No-Op

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
