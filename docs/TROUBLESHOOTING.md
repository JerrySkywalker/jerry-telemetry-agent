# Troubleshooting

## backend usage reports auth_json_missing

Mount or set `CODEX_HOME` so the container can read the local Codex `auth.json`. Do not copy this file into git.

## backend usage reports access_token_missing

Run or re-authenticate Codex CLI on the host. The agent does not refresh OAuth tokens.

Current Codex ChatGPT auth stores the backend token under `tokens.access_token`. The local smoke script reports only `has_access_token=True/False`; it must not print the token value or raw `auth.json`.

## backend usage returns HTTP 403

Confirm `CODEX_USAGE_ENDPOINT` is `https://chatgpt.com/backend-api/wham/usage`. The older `https://chatgpt.com/backend-api/codex/usage` endpoint is not the primary endpoint and has been observed returning 403.

## host-codex fails

Check that `HOST_CODEX_BIN` exists, is executable, and that `HOST_CODEX_HOME` is mounted and contains authenticated Codex configuration.

## Upload fails

Non-2xx hub responses are treated as failures. Events are written to `SPOOL_DIR` and retried on the next run.

## agent health event missing

Run the safe local or LAX health checks:

```powershell
scripts/smoke-agent-health-local.ps1
scripts/lax-agent-health-status.ps1
```

Daemon mode should emit `telemetry.agent.health` after each collection iteration, including iterations where `codex.usage.snapshot` is skipped as an unchanged duplicate. Once mode needs `--health` or `TELEMETRY_AGENT_HEALTH_ENABLED=true`.

## Primary runtime failure triage

The current primary runtime is the LAX Docker backend usage daemon. Start with safe status only:

```powershell
scripts/lax-agent-status.ps1
scripts/lax-agent-canary-report.ps1
scripts/lax-agent-logs.ps1 -Tail 50
```

Do not restart, rebuild, run `down/up`, change systemd, rewrite secrets, or modify the hub during triage unless there is explicit manual approval.

Check:

- `healthz_ok`
- `container_running`
- `latest_snapshot_status_ok`
- `latest_snapshot_limits_count`
- `agent health event_type=telemetry.agent.health`
- `agent health status_ok`
- `pending_spool_count`
- `hub_latest_event_id`
- `old_timer_active`
- `old_timer_enabled`

## When to rollback Docker daemon

Rollback is appropriate when primary runtime failure criteria persist:

- `status.ok=false` repeatedly.
- `pending_spool_count` keeps increasing.
- Hub latest event id or timestamps stop updating while local snapshots continue advancing.
- Container restart loop.
- Safe status fields indicate auth failure.
- Any secret exposure concern.

Dry-run first:

```powershell
scripts/lax-agent-rollback.ps1
```

Confirmed rollback:

```powershell
scripts/lax-agent-rollback.ps1 -Confirm
```

Rollback must not delete `state/`, `.env`, `.env.bak.*`, old sender files, old collector files, or old systemd unit files.

## When to manually reactivate old fallback

Manual reactivation of the old tmux/status fallback is only for an approved rollback path after Docker primary runtime failure. It requires explicit manual approval.

Before any reactivation decision, run the read-only fallback status:

```powershell
scripts/lax-old-fallback-status.ps1
```

Do not auto-enable `codex-status-telemetry.timer`. Do not start, stop, enable, disable, or edit systemd units during routine troubleshooting.

## status.ok=false

If `latest_snapshot_status_ok=false`, inspect only safe health or summary fields and logs. Common causes include Codex backend auth problems, endpoint failures, or schema changes. Do not print `auth.json`, tokens, raw backend responses, `.env`, or `.env.bak.*`.

## container restart loop

If Compose status shows repeated restarts, collect safe status and logs, then decide between confirmed restart or rollback. Do not run `down/up` for routine troubleshooting.

## auth failure

If safe status fields indicate auth failure, re-authenticate Codex CLI on LAX only through an approved manual process. Do not copy `auth.json`, do not widen `/home/ubuntu/.codex` permissions, and do not bake credentials into Docker images.

## secret exposure concern

If any log, PR diff, script output, or shell history may contain a real secret or token, stop routine operations. Treat rollback and secret rotation as manual incident response. Do not paste the suspected secret into issues, PR comments, docs, or chat.

## Duplicate payload skipped

By default identical payloads are not resent. Set `FORCE_SEND=true` to override.

## CI fails on docker compose config

Run `docker compose config` locally from the repository root. This validates Compose syntax and environment interpolation without building images or contacting Docker Hub.

## LAX daemon reports TELEMETRY_NODE_SECRET unset warning

Run LAX daemon Compose operations with the explicit env file:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml config
```

If the warning only appears without `--env-file .env`, fix the operational command or script. Do not paste `.env` contents.

## LAX status reports env_secret_nonempty=false

Treat this as a production secret persistence issue. Check only whether `.env` exists, whether `TELEMETRY_NODE_SECRET` is non-empty, and the file mode. Do not print the value.

If the secret must be restored, do it manually on LAX outside git and then run:

```powershell
scripts/lax-agent-status.ps1
```

Expected follow-up signals are `env_secret_nonempty=true`, `compose_config_with_env=ok`, and `container_secret_nonempty=true`.

## LAX status reports env_backups_mode_safe=false

`.env.bak.*` files may contain secrets and should be mode `600` or stricter. Fix permissions without printing contents:

```bash
cd ~/jerry-telemetry-agent
chmod 600 .env.bak.*
```

Re-run:

```powershell
scripts/lax-agent-status.ps1
```

Expected signal: `env_backups_mode_safe=true`.

## LAX status reports container_secret_nonempty=false

The running container does not have the telemetry secret. Do not print `.env`. Check `env_secret_nonempty` and `compose_config_with_env`.

If the persisted `.env` is healthy, a confirmed restart may be enough:

```powershell
scripts/lax-agent-restart.ps1
scripts/lax-agent-restart.ps1 -Confirm
```

Do not run `down/up` unless a separate rollback or deployment procedure has explicit approval.

## container_secret_nonempty=true but env_secret_nonempty=false

The running container has a secret, but the persisted `.env` does not. This can survive until the next recreate and then fail. Restore the persisted `.env` secret safely from an approved source without printing it, then verify with the status script. Do not commit `.env` or `.env.bak.*`.

## LAX state snapshot PermissionError

Host reads of `~/jerry-telemetry-agent/state/*.safe.snapshot.json` can fail when Docker wrote files as root. This does not by itself mean the daemon is unhealthy.

Prefer:

```bash
curl -fsS http://127.0.0.1:18081/api/codex/usage/summary
```

Fallback to a container read of the safe snapshot:

```bash
cd ~/jerry-telemetry-agent
docker compose --env-file .env -p jerry-telemetry-agent -f deploy/lax/docker-compose.yml.example -f docker-compose.daemon.yml exec jerry-telemetry-agent node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync("/state/codex-usage-latest.safe.snapshot.json","utf8")); console.log(JSON.stringify({status_ok:s.status?.ok,limits_count:s.limits?.length,observed_at:s.observed_at}))'
```

If permissions need maintenance, adjust only `~/jerry-telemetry-agent/state`. Never widen `/home/ubuntu/.codex` permissions.

## healthz ok but file read fails

Trust the health endpoint and safe summary first. Use `scripts/lax-agent-status.ps1` to collect a safe status summary. Do not fail canary health solely because direct host reads of `state/` fail.

## hub event id not increasing

Compare `hub_latest_event_id`, `hub_latest_received_at`, and `hub_latest_observed_at` across at least one 300 second poll interval:

```powershell
scripts/lax-agent-status.ps1
```

Normal daemon operation can skip duplicate payloads. Investigate only if local snapshots continue advancing while hub event id and timestamps do not advance across expected upload windows.

## healthz ok but hub not updating

Check:

- `pending_spool_count`
- `latest_snapshot_status_ok`
- `latest_snapshot_observed_at`
- daemon logs with `scripts/lax-agent-logs.ps1 -Tail 100`
- hub reachability from LAX

If `pending_spool_count` is increasing, treat it as an upload path issue. If spool remains zero and snapshots are healthy, duplicate suppression may explain a stable hub event id.

## hub latest not updating

Check:

- `healthz_ok=true`
- `latest_snapshot_status_ok=true`
- `pending_spool_count`
- daemon logs with `scripts/lax-agent-logs.ps1 -Tail 100`
- hub latest event id and timestamps from `scripts/lax-agent-status.ps1`

Normal daemon operation can skip duplicate payloads. Event id and `received_at` advance only when the hub accepts a new event.

## pending_spool_count > 0

Spooled events mean uploads failed and will be retried before newly captured payloads. If the count persists across multiple poll intervals, inspect safe logs and hub reachability. Do not print secrets or raw payloads.

If `pending_spool_count` keeps increasing, rollback may be appropriate after confirming hub reachability and daemon health.

## old timer unexpectedly active

If `old_timer_active` is not `inactive` or `old_timer_enabled` is not `disabled`, stop and get manual approval before making any systemd change. Do not run `systemctl stop`, `enable`, `disable`, or edit the timer as part of routine canary observation.

## LAX daemon rollback procedure

Dry-run:

```powershell
scripts/lax-agent-rollback.ps1
```

Execute:

```powershell
scripts/lax-agent-rollback.ps1 -Confirm
```

Rollback runs Compose `down` with `--env-file .env`. It does not delete `state/`, `.env`, `.env.bak.*`, old sender files, or old collector files. It does not enable `codex-status-telemetry.timer` and does not modify the hub.

After rollback, verify healthz no longer responds locally and hub latest no longer receives daemon events. Re-enable any old fallback only with explicit manual approval.

## PR ready check fails with dirty working tree

Commit or stash local changes before running `scripts/pr-ready-check.ps1`. The check requires a clean branch so the PR description and validation results match the code being reviewed.

## Light secret scan fails

Remove forbidden local files such as `.env`, `auth.json`, or raw usage dumps from the repository tree. If the scanner reports a possible token assignment, replace the value with an example placeholder or move the secret to local environment configuration.

## LAX preflight reports missing Codex auth

Run or re-authenticate Codex CLI on the LAX host. Do not copy local `auth.json` into the repository or bake it into Docker.

For LAX Docker mode, mount `/home/ubuntu/.codex:/host-codex-home:ro` and set `CODEX_HOME=/host-codex-home`.

## LAX dry-run fails at docker compose config

Run the preflight first:

```powershell
scripts/lax-backend-usage-preflight.ps1
```

Confirm Docker Compose is available on LAX and that `~/jerry-telemetry-agent/deploy/lax/docker-compose.yml.example` exists. The dry-run writes `~/jerry-telemetry-agent/docker-compose.dry-run.yml` and should not require a telemetry secret.

## LAX dry-run reports snapshot status.ok is not true

Inspect only the safe status fields in `~/jerry-telemetry-agent/state/codex-usage-latest.safe.snapshot.json`, such as `status.error_code`, `status.message`, and `status.http_status`. Do not print or paste `~/.codex/auth.json`.

Common causes:

- `/home/ubuntu/.codex` is not present on LAX.
- `auth.json` exists but does not contain `tokens.access_token`.
- The Codex backend endpoint changed or returned an HTTP error.
- The container did not mount `/home/ubuntu/.codex:/host-codex-home:ro`.

## LAX dry-run reports limits_count is zero

The dry-run requires a successful backend usage snapshot with at least one normalized rate limit. Re-run after confirming Codex CLI is authenticated on the LAX host. If `status.ok=true` but `limits_count=0`, treat it as a schema or backend response change and update tests before any production migration.

## LAX real-once latest event is missing

Do not retry in daemon mode. Check the one-shot container output and spooled events under `~/jerry-telemetry-agent/state/spool`. Confirm `TELEMETRY_OUTPUT_MODE=http,file`, `TELEMETRY_NODE_ID=us-lax-pro-01`, and that the old sender env on LAX contains `TELEMETRY_SECRET`.

The guarded once-upload command is:

```powershell
scripts/lax-agent-real-once-upload.ps1 -ConfirmProductionUpload
```

If the script reports a missing old sender env or missing `TELEMETRY_SECRET`, stop and add the secret manually on LAX outside git. Do not paste the value into logs, docs, PR comments, or shell history.

If the upload command exits successfully but the latest endpoint is stale, inspect the safe container output:

```bash
sed -n '1,220p' /tmp/jerry-telemetry-agent-real-once.stdout
```

Do not print `send-latest.env`, `.env`, `auth.json`, or raw secrets.

Verify the old status timer was not changed:

```bash
systemctl status codex-status-telemetry.timer --no-pager
```

## LAX state files are owned by root

Docker once-runs may write `state/*.json` as root because the container process runs as root. Prefer validating snapshots through the container or via hub latest endpoints instead of changing ownership during production checks.

If a later maintenance workflow needs host-user access to generated state files, fix only the Docker agent deployment state directory and do not touch old sender files:

```bash
sudo chown -R ubuntu:ubuntu ~/jerry-telemetry-agent/state ~/jerry-telemetry-agent/deploy/lax/state
```

## Local backend smoke fails

Run:

```powershell
scripts/smoke-codex-backend-usage-local.ps1
```

The script checks local Codex auth, runs once in file-only mode, and validates that the safe snapshot does not contain forbidden token or identity markers.

Expected success diagnostics include `status_ok=True`, `limits_count` greater than zero, `default_limit_found=True` when the default limit is present, and `spark_limit_found=True` when GPT-5.3-Codex-Spark is present.

If the script reports an HTTP error, use the safe `error_code`, `message`, and `http_status` in the snapshot. Do not inspect or paste token values.
