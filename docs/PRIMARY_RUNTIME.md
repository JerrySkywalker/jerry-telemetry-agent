# LAX Primary Runtime

## Current Primary Runtime

The current primary Codex usage telemetry runtime for LAX is the Docker backend usage daemon.

- Runtime: LAX Docker backend usage daemon
- Event type: `codex.usage.snapshot`
- Node id: `us-lax-pro-01`
- Hostname: `novix-lax-01`
- Collector: `codex-backend-usage`
- Output mode: `file,http`
- Health endpoint: `http://127.0.0.1:18081/healthz` from LAX only

Routine status:

```powershell
scripts/lax-agent-status.ps1
scripts/lax-agent-canary-report.ps1
```

Hub checks:

```text
https://telemetry.jerryskywalker.space/v1/events/latest/codex.usage.snapshot
https://telemetry.jerryskywalker.space/v1/nodes/us-lax-pro-01/latest
```

Only record safe fields from hub responses: event id, timestamps, node id, collector, `status.ok`, and limits count.

## Current Fallback

The old tmux/status collector chain is retained as manual fallback only.

- Runtime: old tmux/status collector
- Event type: `codex.status`
- Expected timer state: `inactive/disabled`
- Old files retained:
  - `~/codex-status-collector`
  - `~/jerry-telemetry-codex-status`
  - existing systemd service/timer files

Fallback status:

```powershell
scripts/lax-old-fallback-status.ps1
```

This script is read-only. It must not enable timers, modify old files, print secrets, or read old env contents.

## Continued Observation

1-hour canary criterion is satisfied. Continue observation:

- 24-hour observation: verify repeated event updates, no sustained `status.ok=false`, no upload backlog, no restart loop, no secret leakage, and old timer remains `inactive/disabled`.
- 72-hour observation: verify no sustained hub upload gaps, no non-zero spool backlog, stable `status.ok=true`, stable `limits_count=2`, and no unexpected daemon restarts.

Do not delete old fallback files without a separate approved cleanup goal.

## Rollback

Dry-run:

```powershell
scripts/lax-agent-rollback.ps1
```

Confirmed Docker daemon rollback:

```powershell
scripts/lax-agent-rollback.ps1 -Confirm
```

Rollback runs Compose `down` for the Docker daemon only. It does not delete state, `.env`, `.env.bak.*`, old sender files, old collector files, or old systemd units.

## Old Fallback Reactivation

Reactivation of the old tmux/status fallback requires explicit manual approval.

- Do not auto-enable `codex-status-telemetry.timer`.
- Do not start or stop systemd units during routine observation.
- Do not delete old files as part of rollback.
- Do not modify production hub, hub database, DNS, or reverse proxy settings.
