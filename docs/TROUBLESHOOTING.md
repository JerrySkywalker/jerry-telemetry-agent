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

## Local backend smoke fails

Run:

```powershell
scripts/smoke-codex-backend-usage-local.ps1
```

The script checks local Codex auth, runs once in file-only mode, and validates that the safe snapshot does not contain forbidden token or identity markers.

Expected success diagnostics include `status_ok=True`, `limits_count` greater than zero, `default_limit_found=True` when the default limit is present, and `spark_limit_found=True` when GPT-5.3-Codex-Spark is present.

If the script reports an HTTP error, use the safe `error_code`, `message`, and `http_status` in the snapshot. Do not inspect or paste token values.
