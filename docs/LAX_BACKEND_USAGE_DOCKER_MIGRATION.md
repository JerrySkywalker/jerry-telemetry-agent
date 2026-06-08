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

The existing LAX production timer remains unchanged until explicit manual approval. Do not stop, disable, or replace it during preflight or dry-run work.

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

`TELEMETRY_OUTPUT_MODE=file,http` is documented for final migration. Use `file` only for initial dry-run validation.

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

## Manual Real-Once Test Plan

Do not run this until the no-upload Docker dry-run succeeds and the production telemetry secret is added manually on LAX outside git.

This is a one-shot upload test only. It must not stop, disable, or modify `codex-status-telemetry.timer`.

1. Confirm the old timer remains active:

```bash
systemctl status codex-status-telemetry.timer --no-pager
```

2. In `~/jerry-telemetry-agent/.env`, set the production secret manually and use one-shot HTTP output:

```text
AGENT_MODE=once
TELEMETRY_OUTPUT_MODE=file,http
TELEMETRY_HUB_URL=https://telemetry.jerryskywalker.space/v1/events
TELEMETRY_NODE_ID=us-lax-pro-01
TELEMETRY_HOSTNAME=novix-lax-01
TELEMETRY_REGION=us-lax
```

3. Run one container invocation:

```bash
docker compose -f deploy/lax/docker-compose.yml.example run --build --rm jerry-telemetry-agent node dist/src/main.js --once --collector codex-backend-usage
```

4. Verify the hub received `codex.usage.snapshot`:

```bash
curl -fsS https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
```

5. Confirm `codex-status-telemetry.timer` is still unchanged:

```bash
systemctl status codex-status-telemetry.timer --no-pager
```

Do not run `docker compose up -d`, do not enable daemon mode, and do not install any new systemd unit during this real-once test.

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
