# Canary Soak Observation

`scripts/canary-soak-readonly.ps1` wraps the live read-only audit for repeated observation.

Default behavior:

- Runs several read-only live-audit samples.
- Sleeps between samples.
- Produces a local aggregate report under `.smoke`.
- Compares restart counts, send timestamp, Hub recent timestamp, active spool, upload failure counters, and marker scan status.

Outputs:

- `canary-soak-summary.md`
- `canary-soak-summary.json`
- `canary-soak-sample-table.md`
- `canary-soak-checklist.md`
- nested live audit reports from the underlying audit run

The default sample count and interval are for manual operations, not CI. CI and static validation should inspect script structure or run only short explicit samples when authorized.

Read-only boundary:

- SSH inspection is allowed only after explicit authorization.
- Service start, stop, restart, enable, disable, and edits are forbidden.
- Docker stop, start, restart, remove, update, compose up, compose down, and compose restart are forbidden.
- Tunnel creation, termination, replacement, and restart are forbidden.
- Config, environment, credential, and spool mutation are forbidden.

Safety policy:

- No raw logs.
- No raw response bodies.
- No secret or token values.
- No LAX Codex runtime mutation.
- No raw Hub public exposure.
- No production rename.
- Archived spool is preserved.

If soak fails, preserve the local evidence and use `scripts/canary-rollback-plan-local.ps1` to render a plan. Do not execute rollback without a separate explicit authorization.
