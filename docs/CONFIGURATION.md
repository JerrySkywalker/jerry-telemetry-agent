# Configuration

Configuration is read from environment variables, CLI flags, and optionally a declarative per-node JSON file. Environment variables and CLI flags remain supported for the LAX migration path.

Required only for HTTP upload:
- `TELEMETRY_HUB_URL`
- `TELEMETRY_NODE_ID`
- `TELEMETRY_NODE_SECRET`

Optional for batch upload:
- `TELEMETRY_HUB_BATCH_URL`; when unset and `TELEMETRY_HUB_URL` ends with `/v1/events`, the agent derives `/v1/events/batch`.
- `TELEMETRY_NODE_KEY_ID`; when set, signed requests include `X-Telemetry-Key-Id`.

Each node must use a unique `TELEMETRY_NODE_ID` and a unique `TELEMETRY_NODE_SECRET`. The secret is supplied outside git and is used only for HMAC upload signing.

Runtime:
- `AGENT_MODE=daemon|once`
- `CODEX_USAGE_POLL_INTERVAL_SECONDS=300`
- `AGENT_INTERVAL_SECONDS=600` legacy fallback for poll interval
- `TELEMETRY_COLLECTOR_MODE=codex-backend-usage|codex-cli-status-fallback`
- Generic server collector names: `node-info`, `node-resources`, `service-health`, `http-probe`, `tcp-probe`, `docker-containers`, `systemd-units`, `custom-json`
- `TELEMETRY_NODE_CONFIG_PATH=/config/node.json`
- `TELEMETRY_ENABLE_TMUX_FALLBACK=false`
- `TELEMETRY_OUTPUT_MODE=stdout,file,http`
- `TELEMETRY_OUTPUT_FILE=/state/codex-usage-latest.safe.snapshot.json`
- `CODEX_USAGE_LATEST_PATH=/state/codex-usage-latest.safe.snapshot.json`
- `CODEX_USAGE_LAST_GOOD_PATH=/state/codex-usage-last-good.safe.snapshot.json`
- `CODEX_HOME=~/.codex` on Unix-like hosts, `%USERPROFILE%\.codex` on Windows
- `CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage`
- `CODEX_PROVIDER=backend-usage|file|host-codex|container-codex`
- `STATE_PATH=/state/agent-state.json`
- `SPOOL_DIR=/state/spool`
- `SPOOL_MAX_FILES=100`
- `SPOOL_MAX_BYTES=10485760`
- `FORCE_SEND=false`
- `TELEMETRY_NODE_ID`
- `TELEMETRY_NODE_ROLE`
- `TELEMETRY_ACCOUNT_LABEL`
- `TELEMETRY_CUSTOM_JSON_PATH` optional local custom-json fixture/file path, max 64 KiB.
- `TELEMETRY_SERVICE_HEALTH_PATH` optional local service-health fixture/static file path.
- `TELEMETRY_BATCH_OUTPUT_FILE=.smoke/telemetry-batch.safe.json`
- `TELEMETRY_SERVER_BATCH_LATEST_FILE=/state/server-batch-latest.safe.json`

Health:
- `HEALTH_SERVER_ENABLED=true`
- `HEALTH_HOST=0.0.0.0`
- `HEALTH_PORT=8081` controls the container listener port.
- `HEALTH_HOST_PORT=18081` controls the localhost host port in Docker Compose.
- Generic server daemon summaries are available at `/api/server/status` and `/api/server/batch/latest` when the local health server is enabled. Example templates bind the health port to localhost/private interfaces only.

Fallback:
- `CODEX_STATUS_LATEST_PATH=/input/latest.json`
- `HOST_CODEX_BIN=/host-bin/codex`
- `HOST_CODEX_HOME=/host-codex-home`
- `CODEX_TMUX_SESSION=codex-status-agent`

## Command Examples

Backend usage once, stdout only, no upload:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_NODE_ID="local-dev"
$env:TELEMETRY_OUTPUT_MODE="stdout"
$env:HEALTH_SERVER_ENABLED="false"
npm run dev -- --once --collector codex-backend-usage
```

Backend usage once, safe file only, no upload:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_OUTPUT_MODE="file"
$env:TELEMETRY_OUTPUT_FILE=".smoke/codex-usage-latest.safe.snapshot.json"
$env:HEALTH_SERVER_ENABLED="false"
npm run dev -- --once --collector codex-backend-usage
```

HTTP upload is enabled only when `TELEMETRY_OUTPUT_MODE` includes `http` and all upload settings are present.

## Local One-Shot Batch Examples

Fixture file-only, no Hub and no secrets:

```powershell
.\scripts\agent-once.ps1 -Mode Fixture -Output FileOnly -NodeId local-win-dev-01 -OutFile .smoke\fixture.batch.safe.json
```

Local Windows file-only, no Codex auth and no user-folder scan:

```powershell
.\scripts\agent-once.ps1 -Mode LocalWindows -Output FileOnly -NodeId local-win-dev-01 -OutFile .smoke\local.batch.safe.json
```

Fixture push to an already-running local Hub:

```powershell
.\scripts\agent-once.ps1 -Mode Fixture -Output Push -HubUrl http://127.0.0.1:3000 -NodeId sample-node -WriteSecret <dev-secret> -ReadToken <dev-read-token>
```

Push mode posts to `/v1/events/batch`. If `ReadToken` is supplied, the script checks `/v1/nodes`, `/v1/summary`, `/v1/services`, and `/v1/custom` without printing response bodies. Static read tokens are local/server-side test inputs and must not be embedded in browser, mobile, watch, or notification bundles.

## Local Sibling Hub E2E

The auto-started E2E harness does not require manual dev secrets:

```powershell
.\scripts\smoke-local-hub-agent-e2e.ps1 -Mode Once
.\scripts\smoke-local-hub-agent-e2e.ps1 -Mode Daemon
```

Defaults:

- Agent repo: `V:\src\jerry-telemetry-agent`
- Hub repo: `V:\src\jerry-telemetry-hub`
- Hub host: `127.0.0.1`
- preferred Hub port: `3300`, with a free localhost port selected if needed
- SQLite path: `.smoke\local-hub-agent-e2e\<run>\telemetry.sqlite3`

The harness sets Hub child-process env only:

- `HOST=127.0.0.1`
- `PORT=<local-port>`
- `SQLITE_PATH=<temp-sqlite-path>`
- `TELEMETRY_NODE_SECRETS=<generated-node-id>:<generated-write-secret>`
- `TELEMETRY_READ_AUTH_ENABLED=true`
- `TELEMETRY_READ_AUTH_ALLOW_LOCALHOST=false`
- `TELEMETRY_READ_TOKEN_NAME=local-e2e`
- `TELEMETRY_READ_TOKEN_SHA256=<generated-read-token-sha256>`

The generated write secret, read token, and read token hash are not printed and are not written to reusable config files.

## Server One-Shot Batch Examples

Local file-only server batch:

```powershell
.\scripts\server-agent-once.ps1 -Config .\deploy\examples\general-linux-agent.node.json -Output FileOnly -OutFile .smoke\server.batch.safe.json
```

Local smoke:

```powershell
.\scripts\smoke-server-agent.ps1
```

Read-only Linux preflight template:

```powershell
.\scripts\preflight-linux-agent.ps1
```

The server one-shot path uses `npm run server:once` under the wrapper script. It writes a v1 batch for Hub `/v1/events/batch`, but file output is the default validation mode.

## Server Daemon Examples

Bounded local file-only daemon run:

```powershell
.\scripts\server-agent-daemon.ps1 -Config .\deploy\examples\general-linux-agent.node.json -Output FileOnly -MaxIterations 2 -IntervalSeconds 1
```

Daemon smoke:

```powershell
.\scripts\smoke-server-daemon.ps1
```

NPM entrypoint:

```powershell
npm run server:daemon -- --config .\deploy\examples\general-linux-agent.node.json --output-mode file --max-iterations 2
```

HTTP batch daemon mode uses `TELEMETRY_OUTPUT_MODE=file,http`, `TELEMETRY_HUB_URL` ending in `/v1/events` or explicit `TELEMETRY_HUB_BATCH_URL`, and `TELEMETRY_NODE_SECRET` supplied outside git. The daemon retries sanitized batch spool files before uploading a newly collected batch.

Safe persisted daemon state can include batch timestamps, event types, counts,
and internal file or node bookkeeping. Local health/status HTTP DTOs never expose
node ID, hostname, filesystem paths, or raw error text: they return only
allowlisted booleans, counts, timestamps, versions, and collector categories.
State does not include secrets, raw event payloads, response bodies, logs, or
environment values.

Batch spool limits are controlled by `SPOOL_MAX_FILES` and `SPOOL_MAX_BYTES`. When exceeded, the daemon drops oldest batch spool files and records a safe status; it never stores headers, signatures, secrets, or raw responses in spool files.

## Config Doctor

Use the local config doctor before packaging or manual deployment:

```powershell
.\scripts\doctor-agent-config.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
```

Strict production-style validation requires an env file supplied outside git:

```powershell
.\scripts\doctor-agent-config.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json -EnvPath .smoke\strict-production.local.env -StrictProduction -NoNetwork
```

The doctor reports booleans, counts, statuses, and missing variable names only. It does not print secret values, raw env contents, Codex auth paths, HMAC signatures, Authorization headers, cookies, raw request bodies, or backend raw responses.

`codex-backend-usage` is the primary collector. `codex-cli-status-fallback` and tmux `/status` capture are migration fallbacks only and remain disabled by default.

## Declarative Node Config

`TELEMETRY_NODE_CONFIG_PATH` may point at a JSON file with node identity and allowlisted collectors:

```json
{
  "node_id": "us-lax-pro-01",
  "hostname": "novix-lax-01",
  "region": "us-lax",
  "role": "codex-node",
  "collectors": [
    { "name": "codex-backend-usage", "enabled": true, "interval_seconds": 300 },
    { "name": "agent-health", "enabled": true, "interval_seconds": 300 }
  ]
}
```

Allowed collector names are `codex-backend-usage`, `codex-cli-status-fallback`, `agent-health`, `node-info`, `node-resources`, `service-health`, `http-probe`, `tcp-probe`, `docker-containers`, `systemd-units`, and `custom-json`. Unknown names fail closed at startup. Collector-specific configuration is typed by the registry; arbitrary shell command collectors are intentionally not supported.

Linux server config example:

```json
{
  "node_id": "example-linux-01",
  "hostname": "example-linux-01",
  "region": "local",
  "role": "general-linux-node",
  "provider": "local",
  "collectors": [
    { "name": "node-info", "enabled": true, "interval_seconds": 60 },
    { "name": "node-resources", "enabled": true, "interval_seconds": 60 },
    {
      "name": "http-probe",
      "enabled": true,
      "targets": [
        { "name": "local-hub-health", "url": "http://127.0.0.1:3000/healthz", "timeout_ms": 2000 }
      ]
    },
    {
      "name": "tcp-probe",
      "enabled": true,
      "targets": [
        { "name": "ssh-local", "host": "127.0.0.1", "port": 22, "timeout_ms": 1000 }
      ]
    },
    { "name": "docker-containers", "enabled": false, "allowlist": ["jerry-*", "nginx", "openresty"] },
    { "name": "systemd-units", "enabled": false, "units": ["docker.service", "nginx.service"] },
    {
      "name": "custom-json",
      "enabled": false,
      "files": [
        { "name": "example", "path": "/var/lib/jerry-telemetry-agent/custom/example.json" }
      ]
    },
    { "name": "agent-health", "enabled": true, "interval_seconds": 60 }
  ]
}
```

HTTP probes allow only `GET` and `HEAD`, enforce `timeout_ms`, and omit response bodies and headers. TCP probes check one configured host and port only. `systemd-units` requires an explicit `units` allowlist when enabled. `custom-json.files[].path` must be a local path, not a remote URL.

For a non-LAX pilot that does not collect Codex usage, enable only `agent-health`:

```json
{
  "node_id": "example-node-01",
  "hostname": "example-node-01",
  "region": "example-region",
  "role": "general-node",
  "collectors": [
    { "name": "agent-health", "enabled": true, "interval_seconds": 300 }
  ]
}
```

The checked-in examples are:
- `deploy/examples/non-lax-agent-health.node.json`
- `deploy/examples/non-lax-pilot.env.example`

The example env keeps `TELEMETRY_OUTPUT_MODE=file` so the pilot runs locally without production upload. It includes `TELEMETRY_HUB_URL=https://telemetry.jerryskywalker.space/v1/events` for the future approved upload path, but HTTP output must not be enabled until a real node secret is manually supplied outside git.

Env and CLI compatibility rules:
- `--collector` overrides `TELEMETRY_COLLECTOR_MODE`.
- `TELEMETRY_COLLECTOR_MODE` overrides the first enabled usage collector in the node config.
- `TELEMETRY_NODE_ID`, `TELEMETRY_HOSTNAME`, `TELEMETRY_REGION`, and `TELEMETRY_NODE_ROLE` override the matching node config fields.
- If no node config is provided, the default usage collector remains `codex-backend-usage`.

The LAX production target remains:
- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HOSTNAME=novix-lax-01`
- `TELEMETRY_REGION=us-lax`
- `TELEMETRY_OUTPUT_MODE=file,http`

For Docker backend usage mode, mount the host Codex auth directory read-only and set `CODEX_HOME` to that mount. The image must not include `auth.json`; the host only needs Docker and an installed/authenticated Codex CLI.
