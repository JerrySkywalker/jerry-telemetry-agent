# Providers

## file

Reads `CODEX_STATUS_LATEST_PATH`, validates it as Codex latest JSON, redacts sensitive fields, and returns it.

## host-codex

Uses a host-mounted Codex binary and host-mounted Codex home:
- `HOST_CODEX_BIN=/host-bin/codex`
- `HOST_CODEX_HOME=/host-codex-home`
- `CODEX_TMUX_SESSION=codex-status-agent`

The container starts tmux, runs Codex, sends `/status`, captures the pane, redacts, parses, and uploads. Missing binary or home paths fail clearly.

## container-codex

Reserved for a future container-installed Codex command. The provider interface already supports adding it.
