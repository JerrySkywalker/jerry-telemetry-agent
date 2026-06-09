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

## Duplicate payload skipped

By default identical payloads are not resent. Set `FORCE_SEND=true` to override.

## CI fails on docker compose config

Run `docker compose config` locally from the repository root. This validates Compose syntax and environment interpolation without building images or contacting Docker Hub.

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
