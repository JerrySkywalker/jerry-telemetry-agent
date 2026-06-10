# Agent Health Event

The LAX agent emits `telemetry.agent.health` as a push-based health signal to the telemetry hub. This event is the production source for remote monitor agent health checks; beijing monitor must not SSH to LAX by default.

## Event

- `event_type`: `telemetry.agent.health`
- Payload `type`: `telemetry.agent.health`
- Payload `schema_version`: `1`
- Default node: `us-lax-pro-01`
- Default output file: `/state/agent-health-latest.safe.snapshot.json`

The daemon emits one health event after each usage collection iteration. It also emits health when the usage snapshot is unchanged and skipped by payload hash dedupe. `once` mode can emit one health event with `--health` or `TELEMETRY_AGENT_HEALTH_ENABLED=true`.

## Safe Payload

The payload contains only safe fields:

- node id, hostname, region, platform
- agent name, version, mode, uptime, start time
- boolean health status and safe message category
- collector enabled state, last success/error timestamps, safe error code, usage status, limits count
- output modes, last HTTP success/error timestamps, pending spool count
- configuration summary for poll interval, provider, tmux fallback, local health server
- security booleans such as `node_secret_present`

It never includes raw environment, `TELEMETRY_NODE_SECRET`, read tokens, Authorization headers, Codex tokens, account ids, raw `auth.json`, raw backend responses, or full logs. `raw_omitted_keys` records omitted sensitive categories as marker names only.

## Configuration

```text
TELEMETRY_AGENT_HEALTH_ENABLED=true
TELEMETRY_AGENT_HEALTH_EVENT_TYPE=telemetry.agent.health
TELEMETRY_AGENT_HEALTH_INTERVAL_SECONDS=300
TELEMETRY_AGENT_HEALTH_OUTPUT_FILE=/state/agent-health-latest.safe.snapshot.json
```

Daemon mode defaults health on. Once mode defaults health off unless `--health` or `TELEMETRY_AGENT_HEALTH_ENABLED=true` is set.

## Local Smoke

```powershell
npm run build
scripts/smoke-agent-health-local.ps1
```

The local smoke uses file fallback input, writes safe usage and health snapshots, does not read Codex `auth.json`, and does not upload to production.

## LAX Smoke

```powershell
scripts/lax-agent-health-once.ps1 -ConfirmProductionUpload
scripts/lax-agent-health-status.ps1
```

The guarded once command uses the production `.env` on LAX without printing it. It sends a real `telemetry.agent.health` event through the existing HMAC HTTP sink.

## Rollback

Rollback remains the Docker daemon rollback:

```powershell
scripts/lax-agent-rollback.ps1 -Confirm
```

Rollback does not enable `codex-status-telemetry.timer`, delete state, delete old fallback files, or modify the telemetry hub.
