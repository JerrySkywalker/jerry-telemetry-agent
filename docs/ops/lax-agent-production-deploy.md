# LAX Agent Production Deploy

Production target:

- node_id: `us-lax-pro-01`
- hostname: `novix-lax-01`
- deploy mode: local `git archive` to LAX, then Docker build on LAX
- production path: `/home/ubuntu/jerry-telemetry-agent`
- health check: `http://127.0.0.1:18081/healthz`

LAX is not a git worktree and the host must not run `npm ci`, `npm build`, or tests. Host prerequisites are Docker and an installed/authenticated Codex CLI for host-codex mode.

## Preflight

Run from clean local `main`:

```powershell
git checkout main
git pull --ff-only
npm run typecheck
npm test
npm run build
docker compose config
.\scripts\check-compose-health-port.ps1
.\scripts\scan-secrets-light.ps1
.\scripts\deploy-lax-agent-archive.ps1 -DryRun
```

The dry-run is local only. It does not SSH or SCP and prints only planned paths, booleans, and expected ports.

## Deploy

Deploy only after an approved production window:

```powershell
.\scripts\deploy-lax-agent-archive.ps1 -ConfirmDeploy
```

The deploy script:

- requires local clean `main` when archiving `main`
- creates the archive from tracked files at the selected ref
- uploads the archive to `/tmp` on LAX
- creates a timestamped backup path
- preserves `.env`, `.env.*`, `logs/`, `state/`, `deploy/*/.env`, and `deploy/*/state/`
- uses Docker Compose with the root `docker-compose.yml` and `deploy/lax/.env`
- validates `docker compose config`
- builds and recreates the container
- checks `127.0.0.1:18081/healthz`

Safe deploy output is limited to:

```text
archive_created=true
archive_uploaded=true
backup_path=...
compose_config_ok=true
healthz_18081_ok=true
auth_json_printed=false
raw_backend_printed=false
secret_leak_detected=false
```

Do not print `.env`, state JSON, Codex `auth.json`, backend usage responses, bearer tokens, account ids, user ids, or spool payloads.

## Port Contract

`HEALTH_PORT` is the container listener and defaults to `8081`.

`HEALTH_HOST_PORT` is the LAX localhost binding and defaults to `18081`.

These names must remain separate. The LAX production health check is always the host-side `127.0.0.1:18081/healthz` unless a future ADR changes it.

## Rollback

Use the timestamped `backup_path` printed by the deploy script. Rollback should preserve current state/logs before replacing the app directory, then run Docker Compose from the restored directory and verify:

```text
healthz_18081_ok=true
usage_marker_present=false
health_marker_present=false
state_marker_present=false
spool_count=0
```

If a future deploy reintroduces an `auth.json` marker, stop the rollout, keep the backup, do not cat state or raw payloads, and run `scripts/diag-lax-agent-safe.ps1`.
