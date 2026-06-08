# Providers And Collectors

## codex-backend-usage

Default collector. Reads `CODEX_HOME/auth.json`, extracts a ChatGPT-managed `access_token`, and calls `CODEX_USAGE_ENDPOINT`.

Default endpoint:

```text
https://chatgpt.com/backend-api/wham/usage
```

The agent does not call OAuth refresh endpoints. Codex CLI remains responsible for maintaining auth.

The raw response is normalized internally and discarded. Sinks receive only `codex.usage.snapshot`.

## file

Migration fallback only. Reads `CODEX_STATUS_LATEST_PATH`, validates it as Codex latest JSON, redacts sensitive fields, and adapts it to `codex.usage.snapshot`.

## host-codex

Fallback only. Disabled unless `TELEMETRY_ENABLE_TMUX_FALLBACK=true` or `--collector codex-cli-status-fallback` is used.

Uses a host-mounted Codex binary and host-mounted Codex home:
- `HOST_CODEX_BIN=/host-bin/codex`
- `HOST_CODEX_HOME=/host-codex-home`
- `CODEX_TMUX_SESSION=codex-status-agent`

The container starts tmux, runs Codex, sends `/status`, captures the pane, redacts, parses, and uploads. Missing binary or home paths fail clearly.

## container-codex

Reserved for a future container-installed Codex command. The provider interface already supports adding it.

## LAX backend usage Docker mode

Use `CODEX_PROVIDER=backend-usage` for the primary Docker migration path. The provider value is explicit documentation for operators; the backend collector reads `CODEX_HOME` directly and does not invoke the tmux fallback provider path.
