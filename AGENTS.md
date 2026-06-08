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
