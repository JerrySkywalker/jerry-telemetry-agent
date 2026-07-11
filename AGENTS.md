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

MG-44 workstation exception:
- The co-located Message Gateway readiness collector is a separate workstation runtime; it does not replace or modify the LAX Docker runtime.
- Its reviewed production shape is a native Windows service over immutable release slots with a bundled, digest-pinned Node 22 runtime.
- It must default to file-only output with the collector disabled, use loopback-only Gateway and health targets, and require a protected signing-secret reference outside release slots.
- No global Node, production Git checkout, production npm/build step, or LAX identity may be reused for this workstation boundary.

PR governance:
- `main` is stable.
- Future Codex work should use feature branches and PRs.
- Run `scripts/validate-local.ps1` and `scripts/scan-secrets-light.ps1` before marking a PR ready.
- CI must pass before merge.
- Do not deploy from PR branches.
- Do not deploy to LAX, stop the current LAX systemd timer, modify the production hub, or add production secrets without explicit manual approval.

Autonomous Git/PR policy:
- When a goal explicitly allows autonomous development, Codex may create a feature branch, commit, push, open a PR, wait for CI, and squash-merge if safety checks pass.
- Prefer `scripts/run-goal-pr.ps1` for autonomous PR setup, validation, commit, push, and PR creation.
- Prefer `scripts/merge-pr-if-green.ps1` for guarded auto-merge.
- Auto-merge is forbidden when CI fails, high-risk production files are touched, obvious secret markers appear in the diff, or the goal involves LAX deployment or production hub changes.
- After a successful autonomous merge, return to `main` and pull the latest `origin/main`.
