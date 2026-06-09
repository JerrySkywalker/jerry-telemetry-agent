# jerry-telemetry-agent

Dockerized node-side telemetry agent for Jerry telemetry hub.

Primary Codex collection now reads local Codex `auth.json`, uses the ChatGPT-managed access token to call `https://chatgpt.com/backend-api/wham/usage`, normalizes the response into `codex.usage.snapshot`, and emits it through stdout, file, or HTTP sinks. The tmux `/status` collector is fallback only.

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

For migration fallback file mode:

```powershell
$env:CODEX_STATUS_LATEST_PATH="fixtures/latest.json"
npm run dev -- --once --collector codex-cli-status-fallback --provider file
```

For LAX Docker backend usage mode, the host prerequisites are Docker and an installed/authenticated Codex CLI. The container mounts the host Codex auth directory read-only; it must not bake `auth.json` into the image. See [docs/LAX_BACKEND_USAGE_DOCKER_MIGRATION.md](docs/LAX_BACKEND_USAGE_DOCKER_MIGRATION.md).

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

The LAX backend usage Docker daemon is the current canary runtime and primary candidate for Codex usage telemetry. It emits `codex.usage.snapshot` for `us-lax-pro-01`; the old tmux/status chain is retained as manual fallback only.

```powershell
scripts/lax-agent-status.ps1
scripts/lax-agent-logs.ps1 -Tail 50
scripts/lax-agent-canary-report.ps1
scripts/lax-agent-rollback.ps1
```

Do not re-enable the old timer or delete old sender/collector files without a separate approved cleanup or rollback goal.

Do not put real telemetry secrets in git. The agent never logs `TELEMETRY_NODE_SECRET`, access tokens, refresh tokens, raw `auth.json`, or raw backend usage responses.

## Development Workflow

Future development uses PR-based governance even when local work is done in YOLO mode:

```powershell
scripts/new-pr-branch.ps1 feat/backend-usage-hardening
scripts/pr-ready-check.ps1
```

PRs target `main`, must pass CI, and must not deploy to LAX or modify the production hub. Production LAX migration requires explicit manual approval.

See [docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md) and [docs/CD_PLAN.md](docs/CD_PLAN.md).
