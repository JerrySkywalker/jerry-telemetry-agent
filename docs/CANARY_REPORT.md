# LAX Daemon Canary Observation Report

Observation time: `2026-06-09T10:33:14Z` from safe LAX status and hub latest checks.

## Current Status Summary

The LAX Docker backend usage daemon is healthy at the latest observation and is ready to be treated as the current primary Codex usage telemetry runtime, subject to continued healthy observation.

- Node id: `us-lax-pro-01`
- Hostname: `novix-lax-01`
- Runtime: Docker backend usage daemon
- Collector: `codex-backend-usage`
- Event type: `codex.usage.snapshot`
- Output mode: `file,http`
- Health endpoint: `http://127.0.0.1:18081/healthz` from LAX only
- Old fallback: `codex-status-telemetry.timer` remains `inactive/disabled`

## Latest Safe Observation

- `ssh_ok=true`
- `project_dir_exists=true`
- `env_file_exists=true`
- `env_secret_nonempty=true`
- `env_file_mode=600`
- `env_backup_count=2`
- `env_backups_mode_safe=true`
- `container_running=true`
- `container_secret_nonempty=true`
- `compose_config_with_env=ok`
- `healthz_ok=true`
- `pending_spool_count=0`
- `latest_snapshot_status_ok=true`
- `latest_snapshot_limits_count=2`
- `old_timer_active=inactive`
- `old_timer_enabled=disabled`

Hub latest safe fields:

- Latest event id: `47`
- Latest received at: `2026-06-09T10:33:14Z`
- Latest observed at: `2026-06-09T10:33:13Z`
- Node id: `us-lax-pro-01`
- Collector: `codex_backend_usage`
- `status.ok=true`
- `limits_count=2`

The latest node endpoint also points at event id `47` with matching node, collector, status, and limits count.

## Event Progression

Recent observation showed hub latest moving from event id `43` to `44` over one polling interval before this report. This goal then observed event ids `45`, `46`, and `47`, confirming continued event progression during canary observation.

## Logs

`scripts/lax-agent-logs.ps1 -Tail 50` showed only daemon startup lines plus the local warning reminder. No secret leakage was observed in the checked log tail.

## Known Remaining Limitations

- Direct host reads of `state/codex-usage-latest.safe.snapshot.json` may still be restricted because Docker can write state files with container-owned permissions.
- This is non-blocking while `healthz`, `/api/codex/usage/latest`, container-safe reads, and hub latest checks remain healthy.
- Do not broaden `/home/ubuntu/.codex` permissions.
- `.env` and `.env.bak.*` remain secret files and must not be printed, copied into the repository, or committed.

## Promotion Recommendation

The new LAX Docker backend usage daemon can be treated as the current primary Codex usage telemetry runtime if the latest observation remains healthy.

The old tmux/status chain remains manual fallback only:

- Do not delete old collector or sender files yet.
- Do not re-enable `codex-status-telemetry.timer` unless rollback requires it and explicit manual approval is given.
- Do not make the health endpoint public.
- Continue using `scripts/lax-agent-status.ps1` and `docs/CANARY_CHECKLIST.md` for 24-hour and 72-hour observation gates.
