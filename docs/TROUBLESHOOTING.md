# Troubleshooting

## backend usage reports auth_json_missing

Mount or set `CODEX_HOME` so the container can read the local Codex `auth.json`. Do not copy this file into git.

## backend usage reports access_token_missing

Run or re-authenticate Codex CLI on the host. The agent does not refresh OAuth tokens.

## backend usage returns HTTP 403

Confirm `CODEX_USAGE_ENDPOINT` is `https://chatgpt.com/backend-api/wham/usage`. The older `https://chatgpt.com/backend-api/codex/usage` endpoint is not the primary endpoint and has been observed returning 403.

## host-codex fails

Check that `HOST_CODEX_BIN` exists, is executable, and that `HOST_CODEX_HOME` is mounted and contains authenticated Codex configuration.

## Upload fails

Non-2xx hub responses are treated as failures. Events are written to `SPOOL_DIR` and retried on the next run.

## Duplicate payload skipped

By default identical payloads are not resent. Set `FORCE_SEND=true` to override.
