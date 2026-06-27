# Telemetry Stack Operator Handoff

This handoff is for reviewing a local RC-quality telemetry stack baseline. It is not deployment approval.

## Review Inputs

- Latest Agent PR for the stack RC gate.
- `.smoke\stack-rc\stack-rc-<timestamp>\stack-rc-report.md`
- `.smoke\stack-rc\stack-rc-<timestamp>\stack-rc-report.json`
- `.smoke\stack-rc\stack-rc-<timestamp>\stack-rc-manifest.json`
- Agent package manifest from the same run.
- Hub and Agent CI status.

## Operator Checklist

- Confirm the Agent PR only changes Agent scripts, tests, docs, deploy examples, or local validation tooling.
- Confirm the Hub repository was used read-only for this goal.
- Confirm the RC report says production mutation is false.
- Confirm the Hub and Agent commit SHAs match the intended baseline.
- Confirm Hub and Agent release gates passed in the stack RC run.
- Confirm Once and Daemon E2E passed against the sibling Hub.
- Confirm the Agent package artifact excludes secrets, state, logs, `.smoke`, and dependency folders.
- Confirm no real secret, token, raw log, raw response body, or full environment was included in reports or PR text.

## Before Any Future Deployment

Separate manual approval is required for:

- Target node.
- Hub endpoint.
- Node secret creation and storage location.
- Read-token handling for local verification only.
- Backup path.
- Rollback plan.
- Deployment window.
- Whether the current LAX Codex runtime remains untouched or is migrated in a later approved goal.

Do not paste real secrets or generated credential values into ChatGPT, GitHub, docs, or local reports. Use a local terminal, server-side environment, or a secret manager for secret handling in a future approved deployment.

## Handoff Result

An RC-quality handoff is complete when the stack RC gate passes, the draft PR is open, CI is reported, and the operator has the generated report paths plus the PR link. It does not authorize deployment, tagging, release, or production service changes.
