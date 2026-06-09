# LAX Daemon Canary Checklist

## Current Canary State

The LAX Docker daemon canary is running on `us-lax-pro-01` / `novix-lax-01` with collector `codex-backend-usage`.

- Output mode: `file,http`
- Poll interval: `300s`
- Health endpoint: `127.0.0.1:18081->8081` only
- Expected health: `ok=true`
- Expected event type: `codex.usage.snapshot`
- Expected snapshot: `status.ok=true`, `limits_count=2`
- Old `codex-status-telemetry.timer`: must remain `disabled` and `inactive`

Use the status helper for routine checks:

```powershell
scripts/lax-agent-status.ps1
```

## 1 Hour Check

- `container_running=true`
- `healthz_ok=True` or `healthz_ok=true`
- `env_secret_nonempty=true`
- `container_secret_nonempty=true`
- `compose_config_with_env=ok`
- `latest_snapshot_status_ok=True` or `latest_snapshot_status_ok=true`
- `latest_snapshot_limits_count=2`
- `hub_latest_event_id` is present
- `hub_latest_received_at` and `hub_latest_observed_at` are recent for the canary window
- `old_timer_active=inactive`
- `old_timer_enabled=disabled`
- Logs show no secret markers or token-shaped values

## 24 Hour Check

- Hub latest `codex.usage.snapshot` is still updating when payload changes.
- `received_at` advances across observation windows when a new event is accepted by the hub.
- `observed_at` advances with fresh collector observations.
- The container has no restart loop in `docker compose --env-file .env ... ps`.
- `pending_spool_count=0` or returns to zero after temporary hub/network issues.
- `.env` exists, is non-empty for `TELEMETRY_NODE_SECRET`, and is mode `600` when possible.
- `.env.bak.*` files are counted only; contents are never printed.

## 72 Hour Check

- No sustained hub upload gaps.
- No sustained non-zero spool backlog.
- No unexpected daemon restarts.
- `status.ok=true` remains stable.
- `limits_count=2` remains stable unless the upstream Codex usage schema changes.
- Old timer remains `disabled/inactive`.
- No secret markers appear in logs, docs, PR diffs, or shell output.

## Failure Criteria

- `healthz_ok=false` for more than one poll interval.
- `latest_snapshot_status_ok=false`.
- `latest_snapshot_limits_count` is empty or changes unexpectedly from `2`.
- `container_secret_nonempty=false`.
- `compose_config_with_env=warning`.
- Hub latest stops updating while local health and collection continue to report success.
- `pending_spool_count > 0` persists across multiple poll intervals.
- Compose shows the container repeatedly restarting.
- Any log, script output, or PR diff contains a real secret, token, raw account id, or raw auth payload.
- Old timer is modified, enabled, or started unexpectedly.

## Rollback Criteria

Rollback the daemon canary if failure criteria persist and a restart is not sufficient, or if there is any credible secret exposure risk.

Dry-run rollback first:

```powershell
scripts/lax-agent-rollback.ps1
```

Execute rollback only with explicit confirmation:

```powershell
scripts/lax-agent-rollback.ps1 -Confirm
```

Rollback only runs:

```bash
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml down
```

Rollback must not delete `state/`, `.env`, `.env.bak.*`, old sender files, or old collector files. It must not enable the old timer automatically.

## Promotion Criteria

- 72-hour observation passes without failure criteria.
- Hub latest and node latest agree on fresh `codex.usage.snapshot` events.
- `status.ok=true` and `limits_count=2` remain stable.
- Container has no restart loop.
- Secret scan and local validation pass.
- Operational docs and rollback instructions are current.
- Promotion receives explicit manual approval. Do not deploy from PR branches.

## How To Confirm Key Signals

Event id should advance when the hub receives a new accepted event:

```powershell
scripts/lax-agent-status.ps1
```

Compare `hub_latest_event_id` across checks.

`received_at` and `observed_at` should update when fresh events are accepted. Compare:

- `hub_latest_received_at`
- `hub_latest_observed_at`
- `latest_snapshot_observed_at`

Confirm safe snapshot status:

- `latest_snapshot_status_ok=true`
- `latest_snapshot_limits_count=2`

Confirm no restart loop:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml ps
```

Confirm logs do not contain secrets:

```powershell
scripts/lax-agent-logs.ps1 -Tail 100
```

Do not paste logs if they unexpectedly contain secrets, tokens, raw account ids, or raw auth payloads.

Confirm old timer remains disabled and inactive:

```bash
systemctl is-active codex-status-telemetry.timer
systemctl is-enabled codex-status-telemetry.timer
```
