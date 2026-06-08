# AGENTS.md

This repository implements Jerry's node-side telemetry agent.

It is independent from SkyBridge, Hermes, Codex, and jerry-telemetry-hub.

The hub receives telemetry. This agent collects telemetry from a node and reports it to the hub.

First production target:
- LAX node
- node_id: us-lax-pro-01
- hostname: novix-lax-01
- first collector: Codex status

Development rules:
- Keep secrets out of git.
- Never print telemetry secrets.
- Never upload raw Codex account or session IDs.
- Prefer TypeScript.
- Docker must contain all agent-side runtime dependencies.
- Host prerequisites should be only Docker and an installed/authenticated Codex CLI when using host-codex mode.
- Support file mode as migration fallback.

PR governance:
- `main` is stable.
- Future Codex work should use feature branches and PRs.
- Run `scripts/validate-local.ps1` and `scripts/scan-secrets-light.ps1` before marking a PR ready.
- CI must pass before merge.
- Do not deploy from PR branches.
- Do not deploy to LAX, stop the current LAX systemd timer, modify the production hub, or add production secrets without explicit manual approval.
