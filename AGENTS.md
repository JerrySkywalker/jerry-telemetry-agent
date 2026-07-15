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

## Branch Model

- main is the required stable source-integration branch.
- dev is an optional tested development-integration branch. It is currently absent and must remain absent unless discovery proves a real downstream, physical-device, external-service, or production-promotion dependency that cannot correctly enter main.
- Every other branch is a short-lived task branch. Do not create an empty policy-only dev branch.
- Do not commit or push directly to main or dev.

## Branch Target Rules

- Start every task branch from exact current main unless a recorded dev decision requires dev.
- Target main for ordinary source and governance work.
- Target dev only when dev_required=true is recorded in a durable discovery receipt and the branch contains real tested content that needs that integration boundary.
- Every branch and pull request must have one recorded purpose, owner, target, and finite convergence classification.
- Never use force-push, admin bypass, or check bypass to satisfy branch policy.

## Short-Lived Branch Lifecycle

- create
- implement
- validate
- audit
- PR
- merge to main or dev
- delete remote branch
- delete local branch
- remove worktree

Retain a branch only when its unique history, evidence, worktree, or external dependency is explicitly classified and owned. A merged or abandoned task branch must not remain indefinitely without a recorded reason.

## Single-Writer Rule

- One Implementer Codex is the only repository and Git writer.
- Supervisor Codex and subagents are product-repository read-only.
- Git operations are never executed from V:\src.
- No two concurrent writers may operate on this repository.
- Read-only auditors must not modify files, Git refs, pull requests, worktrees, or coordinator state, and must not recursively spawn agents.

## Agent Allocation

- branch_historian: branch, commit, ref, and merge-history audit
- contract_auditor: repository contract and governance audit
- test_ci_auditor: local gate and CI proof audit
- security_auditor: secret, package, runtime, and boundary audit
- conflict_auditor: worktree, checkout, and overlap audit
- cleanup_archive_auditor: convergence, archive, and evidence-retention audit
- final_exact_head_auditor: final PR head, base, and exact-proof audit
- The Implementer owns the patch, commit, push, PR, and permitted Git mutation. Supporting auditors are direct, read-only, and non-recursive.

## Blocker Handling

- First occurrence of the same blocker fingerprint: require architect analysis.
- Second occurrence of the same blocker fingerprint: require architect analysis plus adversarial audit.
- Third occurrence of the same blocker fingerprint: escalate to a human.
- Escalate immediately to a human for real secrets, identity or signing material, MFA or a physical device, production mutation, irreversible data operation, force-push, unclear unique commits, or deletion of untracked evidence.
- Stop on a blocker; preserve the exact sanitized classification and do not bypass, discard, reset, force, or widen scope.

## Repository-Specific Preservation Rules

- The LAX Docker runtime remains independent of the workstation runtime.
- The workstation runtime does not replace or modify LAX.
- The immutable workstation runtime artifact source and operations main have separate roles.
- Source convergence does not authorize workstation service installation.
- The signing reference remains external to runtime boundaries and is never copied into source, release slots, or runtime state.
- artifacts/playwright/dashboard-mg39b/ is preserved in place as intentional untracked evidence. Do not enumerate its contents, read it, stage it, move it, rename it, delete it, clean it, package it, or include it in runtime inventory.
- Package, Docker-context, and runtime-inventory checks must prove that the preserved evidence path is excluded without reading its contents.
- No telemetry secret or raw account/session data may be emitted.

## Repository Health Completion

Repository health is complete only when:

- main is healthy;
- dev is healthy or explicitly absent;
- every other local and remote branch is classified;
- merged task branches are deleted when exact no-unique-content, no-open-PR, and no-worktree proof is satisfied;
- pull requests are resolved;
- worktrees are resolved or explicitly held with an owner and reason;
- no unique commit or untracked evidence object is unknown;
- required local gates pass;
- CI or an approved exact-head code-equivalence proof passes;
- preservation rules are satisfied.

The repository-health Implementer phase stops before merge at SUPERVISOR_AUDIT_REQUIRED. It does not start the next wave step.
