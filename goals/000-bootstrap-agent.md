# Goal 000: Build Dockerized jerry-telemetry-agent

We are in YOLO development mode. Build the first full version of `jerry-telemetry-agent`.

## Product definition

This is a node-side telemetry agent.

It is independent from:
- SkyBridge
- Hermes
- Codex
- jerry-telemetry-hub

It reports telemetry events to `jerry-telemetry-hub`.

First target:
- LAX node
- node_id: us-lax-pro-01
- hostname: novix-lax-01
- first collector: Codex status

## Core requirement

For Codex telemetry, the host machine should only need:
- Docker Engine
- Codex CLI installed and authenticated

The Docker container should contain all other agent-side runtime components:
- TypeScript/Node runtime
- tmux
- parser
- scheduler
- uploader
- state management
- health server
- retry/spool logic

## Provider modes

Implement three modes:

### 1. file mode

Reads an existing Codex latest JSON file.

Config:
- CODEX_PROVIDER=file
- CODEX_STATUS_LATEST_PATH=/input/latest.json

This mode supports current LAX migration.

### 2. host-codex mode

Runs Codex inside the container using a host-mounted Codex binary and host-mounted Codex auth/config.

Config:
- CODEX_PROVIDER=host-codex
- HOST_CODEX_BIN=/host-bin/codex
- HOST_CODEX_HOME=/host-codex-home
- CODEX_TMUX_SESSION=codex-status-agent

The container should:
- start tmux inside the container
- run HOST_CODEX_BIN
- send /status
- capture pane
- redact
- parse
- upload

If this mode cannot operate due missing binary or auth path, fail clearly.

### 3. container-codex mode

Reserved/fallback mode.

Allow the container to run a container-installed Codex command if present.

Do not require full implementation if uncertain, but design the provider interface so it can be added later.

## Required features

### CLI modes

Support:
- --once
- --daemon
- --dry-run
- --status
- --provider file|host-codex|container-codex

Default behavior comes from env:
- AGENT_MODE=daemon
- AGENT_INTERVAL_SECONDS=600

### Event envelope

Build generic telemetry envelope:

- schema_version = v1
- event_type = codex.status
- source.node_id = TELEMETRY_NODE_ID
- source.hostname = TELEMETRY_HOSTNAME or os.hostname()
- source.region = TELEMETRY_REGION
- source.collector = TELEMETRY_COLLECTOR
- captured_at = send time
- payload = parsed/redacted Codex status JSON

### HMAC upload

Use same HMAC rules as jerry-telemetry-hub:

Payload to sign:
timestamp.nonce.rawBody

Headers:
- X-Telemetry-Node
- X-Telemetry-Timestamp
- X-Telemetry-Nonce
- X-Telemetry-Signature

### State

State file:
- STATE_PATH=/state/agent-state.json

Track:
- last payload captured_at
- last source_file
- last successful send time
- last error

Default:
- avoid re-sending identical status
- FORCE_SEND=true allows repeat sends

### Spool

If upload fails:
- write event to SPOOL_DIR
- retry old spooled events before sending latest
- do not drop data silently

### Health server

If HEALTH_SERVER_ENABLED=true:

Endpoints:
- GET /healthz
- GET /status

Expose:
- provider mode
- last success
- last error
- pending spool count
- last payload captured_at
- node_id
- hostname

### Security

- Never print TELEMETRY_NODE_SECRET.
- Never print full Authorization/token/secret-like env.
- Reject Codex payload if account or session are not redacted.
- Validate latest.json has required fields.
- Non-2xx upload response is failure.

## Repository structure

Create:

- package.json
- package-lock.json
- tsconfig.json
- Dockerfile
- docker-compose.yml
- .env.example
- .gitignore
- .gitattributes
- README.md

Source:

- src/main.ts
- src/config.ts
- src/logger.ts
- src/providers/provider.ts
- src/providers/fileProvider.ts
- src/providers/hostCodexProvider.ts
- src/codex/parseCodexStatus.ts
- src/codex/redactCodexStatus.ts
- src/codex/validateCodexLatest.ts
- src/telemetry/envelope.ts
- src/telemetry/hmac.ts
- src/telemetry/uploader.ts
- src/telemetry/state.ts
- src/telemetry/spool.ts
- src/health/server.ts

Scripts:

- scripts/detect-host-codex.sh
- scripts/smoke-local.ps1

Docs:

- docs/ARCHITECTURE.md
- docs/CONFIGURATION.md
- docs/PROVIDERS.md
- docs/LAX_DEPLOYMENT.md
- docs/OPERATIONS.md
- docs/SECURITY.md
- docs/TROUBLESHOOTING.md
- docs/MIGRATION_FROM_SYSTEMD_SENDER.md

Fixtures:

- fixtures/codex-latest.json
- fixtures/codex-status-pane.txt

Tests:

- tests/hmac.test.ts
- tests/envelope.test.ts
- tests/validateCodexLatest.test.ts
- tests/fileProvider.test.ts
- tests/state.test.ts
- tests/spool.test.ts
- tests/uploader.test.ts
- tests/hostCodexProvider.test.ts if practical

CI:

- .github/workflows/ci.yml
- npm ci
- npm run typecheck
- npm test
- npm run build

## Docker

Docker image should include:
- node runtime
- bash
- tmux
- curl or equivalent diagnostic tool

Docker Compose should include:
- read-only input mount for file mode
- writable state mount
- optional host Codex binary mount examples
- optional host Codex auth/config mount examples
- health port bound to 127.0.0.1

## Validation commands

Run:

- npm install
- npm run typecheck
- npm test
- npm run build
- docker compose config

If Docker build works, run:
- docker compose build

If Docker Hub is unreachable, document and continue.

## Do not

- deploy to LAX yet
- stop current LAX systemd timer
- modify jerry-telemetry-hub
- commit real secrets
- add frontend
- add database server
