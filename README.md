# jerry-telemetry-agent

Generic node-side telemetry agent for Jerry telemetry hub. The first production profile is LAX Codex usage, but Codex usage is one collector profile rather than the whole product.

Primary Codex collection now reads local Codex `auth.json`, uses the ChatGPT-managed access token to call `https://chatgpt.com/backend-api/wham/usage`, normalizes the response into `codex.usage.snapshot`, and emits it through stdout, file, or HTTP sinks. The tmux `/status` collector is fallback only.

The daemon also emits `telemetry.agent.health` after each collection iteration. This push event is the production health source for remote monitors; beijing monitor should read it from the hub instead of SSHing to LAX by default. See [docs/AGENT_HEALTH_EVENT.md](docs/AGENT_HEALTH_EVENT.md).

## Quick Start

```powershell
npm install
npm run typecheck
npm test
npm run build
docker compose config
```

Full local validation:

```powershell
scripts/validate-local.ps1
scripts/scan-secrets-light.ps1
```

For local backend usage stdout mode:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_NODE_ID="local-dev"
npm run dev -- --once
```

For a local backend usage smoke that writes only a safe file and does not upload:

```powershell
scripts/smoke-codex-backend-usage-local.ps1
```

For a local agent health smoke that does not read `auth.json` and does not upload:

```powershell
scripts/smoke-agent-health-local.ps1
```

For local generic server telemetry that does not require Codex auth:

```powershell
.\scripts\agent-once.ps1 -Mode Fixture -Output FileOnly -NodeId local-win-dev-01 -OutFile .smoke\fixture.batch.safe.json
.\scripts\agent-once.ps1 -Mode LocalWindows -Output FileOnly -NodeId local-win-dev-01 -OutFile .smoke\local.batch.safe.json
.\scripts\smoke-local-agent.ps1
```

For a local Hub that is already running at `http://127.0.0.1:3000`, fixture push mode signs and posts a safe batch to `/v1/events/batch`, then reads back `/v1/nodes`, `/v1/summary`, `/v1/services`, and `/v1/custom` when a read token is supplied:

```powershell
.\scripts\agent-once.ps1 -Mode Fixture -Output Push -HubUrl http://127.0.0.1:3000 -NodeId sample-node -WriteSecret <dev-secret> -ReadToken <dev-read-token>
```

The local batch contains `node.snapshot`, `node.resources.snapshot`, `service.health.snapshot`, `custom.snapshot`, and `telemetry.agent.health`. It writes only sanitized JSON and prints only safe status fields.

For migration fallback file mode:

```powershell
$env:CODEX_STATUS_LATEST_PATH="fixtures/latest.json"
npm run dev -- --once --collector codex-cli-status-fallback --provider file
```

For LAX Docker backend usage mode, the host prerequisites are Docker and an installed/authenticated Codex CLI. The container mounts the host Codex auth directory read-only; it must not bake `auth.json` into the image. See [docs/LAX_BACKEND_USAGE_DOCKER_MIGRATION.md](docs/LAX_BACKEND_USAGE_DOCKER_MIGRATION.md).

Production LAX deploy is archive plus Docker build, not git pull or npm on LAX. See [docs/ops/lax-agent-production-deploy.md](docs/ops/lax-agent-production-deploy.md), [docs/ops/lax-agent-diagnostics.md](docs/ops/lax-agent-diagnostics.md), and the MG020 Rescue postmortem at [docs/incidents/2026-06-12-mg020-rescue.md](docs/incidents/2026-06-12-mg020-rescue.md).

Cross-project config and secret governance is tracked from this repo through [docs/governance/JERRY_CONFIG_GOVERNANCE_POINTER.md](docs/governance/JERRY_CONFIG_GOVERNANCE_POINTER.md).

The old tmux/status chain is cold-archived as manual fallback only. See [docs/ops/old-codex-status-chain-cold-archive.md](docs/ops/old-codex-status-chain-cold-archive.md) and [docs/ops/manual-fallback-codex-status.md](docs/ops/manual-fallback-codex-status.md).

LAX preparation commands:

```powershell
scripts/lax-backend-usage-preflight.ps1
scripts/lax-agent-dry-run.ps1
```

The dry-run copies the current committed tree to `~/jerry-telemetry-agent`, creates a non-secret `.env`, runs `docker compose config`, and runs backend usage once with `stdout,file` only. It does not upload to the hub, enable daemon mode, or touch the existing `codex-status-telemetry.timer`.

LAX daemon canary operations:

```powershell
scripts/lax-agent-status.ps1
scripts/lax-agent-logs.ps1 -Tail 100
scripts/lax-agent-rollback.ps1
```

Use [docs/CANARY_CHECKLIST.md](docs/CANARY_CHECKLIST.md) for 1 hour, 24 hour, and 72 hour observation gates. Rollback is dry-run by default and requires `-Confirm` to run Compose `down`.

## Current LAX Runtime

The LAX backend usage Docker daemon is the current primary Codex usage telemetry runtime. It emits `codex.usage.snapshot` for `us-lax-pro-01`; the old tmux/status chain is retained as manual fallback only.
It also emits `telemetry.agent.health` for `us-lax-pro-01`; the local `/healthz` endpoint remains a localhost-only auxiliary check.
In Docker Compose, `HEALTH_PORT` is the container listener port and defaults to `8081`; `HEALTH_HOST_PORT` is the host localhost port and defaults to `18081`, so the LAX health check is `http://127.0.0.1:18081/healthz`.

```powershell
scripts/lax-agent-status.ps1
scripts/lax-agent-health-status.ps1
scripts/lax-agent-logs.ps1 -Tail 50
scripts/lax-agent-canary-report.ps1
scripts/lax-agent-rollback.ps1
scripts/lax-old-fallback-status.ps1
scripts/diag-lax-agent-safe.ps1
```

Do not re-enable the old timer or delete old sender/collector files without a separate approved cleanup or rollback goal.

Do not put real telemetry secrets in git. The agent never logs `TELEMETRY_NODE_SECRET`, access tokens, refresh tokens, raw `auth.json`, or raw backend usage responses.

Local one-shot batch testing is a development workflow only. It does not deploy, change LAX services, modify the production Hub, add dashboard code, or create mobile/watch/notification consumers.

## Development Workflow

Future development uses PR-based governance even when local work is done in YOLO mode:

```powershell
scripts/new-pr-branch.ps1 feat/backend-usage-hardening
scripts/pr-ready-check.ps1
```

PRs target `main`, must pass CI, and must not deploy to LAX or modify the production hub. Production LAX migration requires explicit manual approval.

See [docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md) and [docs/CD_PLAN.md](docs/CD_PLAN.md).
