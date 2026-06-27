# Providers And Collectors

Collectors are selected through a typed allowlist. Implemented names are:
- `codex-backend-usage`
- `codex-cli-status-fallback`
- `agent-health`
- `node-info`
- `node-resources`
- `service-health`
- `http-probe`
- `tcp-probe`
- `docker-containers`
- `systemd-units`
- `custom-json`

Unknown collector names fail closed during config loading. Arbitrary shell command collectors are intentionally not supported. Additional collectors must be added to the registry with an explicit event type and safe payload contract before they can run.

Non-LAX health-only pilots may enable only `agent-health`. In that configuration the agent skips Codex auth reads and backend usage collection, emits `telemetry.agent.health`, and can run with local file output only.

Local generic server testing may enable the local collectors without Codex auth. These collectors are allowlisted by name and do not support arbitrary shell commands.

The generic server daemon uses the same allowlisted server collectors as `server:once`. It is launched through `npm run server:daemon` or `scripts/server-agent-daemon.ps1`, retries batch spool files before new batches, and posts only HMAC-signed v1 batches to Hub `/v1/events/batch` when HTTP output is enabled.

## codex-backend-usage

Default and primary collector. Reads `CODEX_HOME/auth.json`, extracts a ChatGPT-managed `tokens.access_token` or another supported `access_token` schema, and calls `CODEX_USAGE_ENDPOINT`.

Default endpoint:

```text
https://chatgpt.com/backend-api/wham/usage
```

The agent does not call OAuth refresh endpoints. Codex CLI remains responsible for maintaining auth.

The raw response is normalized internally and discarded. Sinks receive only `codex.usage.snapshot`; raw account IDs, user IDs, email, promo, referral beacon, auth tokens, and the full raw response are never emitted.

## file

Migration fallback only. Reads `CODEX_STATUS_LATEST_PATH`, validates it as Codex latest JSON, redacts sensitive fields, and adapts it to `codex.usage.snapshot`.

## host-codex

Fallback only. Disabled unless `TELEMETRY_ENABLE_TMUX_FALLBACK=true` or `--collector codex-cli-status-fallback` is used. `/status` pane capture is not the primary production path.

Uses a host-mounted Codex binary and host-mounted Codex home:
- `HOST_CODEX_BIN=/host-bin/codex`
- `HOST_CODEX_HOME=/host-codex-home`
- `CODEX_TMUX_SESSION=codex-status-agent`

The container starts tmux, runs Codex, sends `/status`, captures the pane, redacts, parses, and uploads. Missing binary or home paths fail clearly.

## container-codex

Reserved for a future container-installed Codex command. The provider interface already supports adding it.

## node-info

Generic server snapshot collector. Emits `node.snapshot` with only node id, hostname, region, role, provider, platform, OS, kernel, architecture, uptime seconds, and agent version.

## node-resources

Generic resource snapshot collector. Emits `node.resources.snapshot` with memory totals/free/percent, load averages where available, uptime, nullable CPU/process metrics when not safely available, disk summaries limited to generic drive or mount labels plus total/free/used percentages and safe filesystem type, and a network status summary without IP or MAC addresses.

## service-health

Fixture/static service-health collector. Emits `service.health.snapshot` with an allowlisted `services` array: name, kind, status, last check, message, response time, and non-sensitive port. It must not emit URLs with credentials, request headers, response bodies, logs, or environment data.

## http-probe

Safe HTTP probe collector. Emits `service.health.snapshot` with name, kind, health status, last check time, response time, status code, sanitized URL, and message. Only `GET` and `HEAD` are allowed. It enforces timeouts, uses bounded redirect behavior, and never emits request headers or response bodies.

## tcp-probe

Safe TCP probe collector. Emits `service.health.snapshot` with name, kind, health status, last check time, response time, port, and message. It checks only explicitly configured single host/port targets and validates ports from 1 to 65535.

## docker-containers

Read-only Docker status collector. Emits `docker.containers.snapshot` from safe `docker ps` formatting. It reports name, sanitized image, status, state, health, optional restart count, optional started timestamp, and host/container port numbers only. It does not inspect containers, print env, print mounts, print labels by default, or require privileged mode.

## systemd-units

Read-only systemd status collector. Emits `systemd.units.snapshot` for configured unit names only. It uses `systemctl show` for safe fields: name, active state, sub state, load state, active-since timestamp, short description, and derived status. It does not call `journalctl`, emit `ExecStart`, print env, or start/stop/restart/enable/disable units.

## custom-json

Fixture/file custom collector. Emits `custom.snapshot` from local paths supplied by config, CLI, or environment. Files are limited to 64 KiB. Output is controlled to name, status, message, observed timestamp, tags, and sanitized `safe_values` only when the file is explicitly marked safe. Raw env, logs, headers, authorization, cookies, tokens, account/user/email fields, secrets, passwords, and `auth.json` markers are omitted.

## LAX backend usage Docker mode

Use `CODEX_PROVIDER=backend-usage` for the primary Docker migration path. The provider value is explicit documentation for operators; the backend collector reads `CODEX_HOME` directly and does not invoke the tmux fallback provider path. Mount the host Codex auth directory read-only, for example `/home/ubuntu/.codex:/host-codex-home:ro`, and set `CODEX_HOME=/host-codex-home`.
