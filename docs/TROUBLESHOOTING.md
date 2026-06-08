# Troubleshooting

## host-codex fails

Check that `HOST_CODEX_BIN` exists, is executable, and that `HOST_CODEX_HOME` is mounted and contains authenticated Codex configuration.

## Upload fails

Non-2xx hub responses are treated as failures. Events are written to `SPOOL_DIR` and retried on the next run.

## Duplicate payload skipped

By default identical payloads are not resent. Set `FORCE_SEND=true` to override.
