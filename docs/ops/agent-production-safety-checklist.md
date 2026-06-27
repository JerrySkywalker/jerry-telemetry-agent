# Agent Production Safety Checklist

Manual approval is required before any production deployment.

Before approval:

- `scripts/release-gate-local.ps1` passes.
- `scripts/package-agent-local.ps1` passes and writes a safe manifest.
- `scripts/doctor-agent-config.ps1` passes for the target config.
- Server daemon smoke passes.
- Local Hub E2E smoke passes when the sibling Hub repo is available.
- The target node config uses allowlisted collectors only.
- Arbitrary shell command collectors are absent.
- HTTP upload is disabled until the operator supplies a node secret outside git.

Secrets:

- Store `TELEMETRY_NODE_SECRET` outside git.
- Never render secret values in docs, plans, artifacts, logs, or PRs.
- Keep env files mode `600` on target hosts.
- Use a unique node secret per node.
- Use `TELEMETRY_NODE_KEY_ID` for key rotation when the Hub side is ready.

Runtime safety:

- Health binds to localhost or an approved private interface.
- State and spool directories are preserved across upgrades.
- Docker and systemd collectors are read-only status collectors.
- HTTP probes omit headers, query strings, fragments, and response bodies.
- TCP probes check only explicitly configured single host/port targets.
- Custom JSON files must be local and safe-summarized.

LAX note:

- Do not alter current LAX runtime without explicit manual approval.
- Existing LAX Codex daemon behavior remains untouched by generic deployment-readiness work.
- Old fallback policies remain as documented in the LAX operations docs.
