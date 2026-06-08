# LAX Backend Usage Docker Migration

This is preparation documentation only. Do not deploy to LAX, stop the current systemd timer, change production hub settings, or add production secrets without explicit manual approval.

## Target

- `TELEMETRY_NODE_ID=us-lax-pro-01`
- `TELEMETRY_HOSTNAME=novix-lax-01`
- `TELEMETRY_REGION=us-lax`
- `TELEMETRY_COLLECTOR=codex-backend-usage`
- `CODEX_PROVIDER=backend-usage`
- `CODEX_HOME=/host-codex-home`
- `CODEX_USAGE_ENDPOINT=https://chatgpt.com/backend-api/wham/usage`

Host prerequisites are Docker and an installed/authenticated Codex CLI. The container must mount `/home/ubuntu/.codex:/host-codex-home:ro`; it must not bake Codex auth into the image.

## Preflight

```powershell
scripts/lax-backend-usage-preflight.ps1
```

The preflight checks Docker, Docker Compose, host Codex, host Codex auth presence, old timer status, hub latest endpoint status, disk, memory, and whether `~/jerry-telemetry-agent` exists. It prints only redacted status.

## Compose Template

Use:

- [deploy/lax/docker-compose.yml.example](../deploy/lax/docker-compose.yml.example)
- [deploy/lax/.env.example](../deploy/lax/.env.example)

The template mounts:

- `/home/ubuntu/.codex:/host-codex-home:ro`
- `./state:/state`

The health endpoint is bound only to localhost:

```text
127.0.0.1:18081:8081
```

`TELEMETRY_OUTPUT_MODE=file,http` is documented for final migration. Use `file` only for initial dry-run validation.

## Safe Local Commands

Local Windows smoke, no upload:

```powershell
scripts/smoke-codex-backend-usage-local.ps1
```

Backend once, stdout only, no upload:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_NODE_ID="local-dev"
$env:TELEMETRY_OUTPUT_MODE="stdout"
$env:HEALTH_SERVER_ENABLED="false"
npm run dev -- --once --collector codex-backend-usage
```

Backend once, file only, no upload:

```powershell
$env:CODEX_HOME="$HOME\.codex"
$env:TELEMETRY_OUTPUT_MODE="file"
$env:TELEMETRY_OUTPUT_FILE=".smoke/codex-usage-latest.safe.snapshot.json"
$env:HEALTH_SERVER_ENABLED="false"
npm run dev -- --once --collector codex-backend-usage
```
