# Telemetry Stack Release Candidate

This is the local release-candidate gate for the telemetry stack. It validates the Agent producer and sibling Hub receiver together before any production deployment is considered.

Run from the Agent repository:

```powershell
.\scripts\stack-release-candidate-local.ps1
```

## Included Scope

- Hub private receiver and read model from the sibling `jerry-telemetry-hub` repository.
- Agent producer, one-shot paths, daemon path, deployment readiness scripts, and package artifact.
- Real local Agent to Hub E2E in once and daemon modes.
- Hub local release gate, including its local SQLite maintenance checks.
- Agent local release gate, package validation, and generated stack RC reports.
- Cross-repo commit, branch, package name, and package version manifest.

## Excluded Scope

- Production deployment or server mutation.
- Dashboard, mobile, watch, notification, proxy, or public BFF work.
- Production secrets, generated credentials, real endpoint values, or raw environment dumps.
- Public API stability guarantees. The checked contract is an integration compatibility contract for the current private stack baseline.

## Required Local State

- Agent working tree on `main` or the stack RC feature branch.
- Hub sibling repository available at `..\jerry-telemetry-hub` for local operator runs.
- Hub checkout on clean `main` with the Hub deployment-readiness merge present.
- Agent checkout clean except local ignored output.
- No real `.env` contents or node secrets printed into terminal output, reports, docs, or PR text.

In CI or static-only environments, sibling-Hub runtime checks may be skipped only by an explicit allow/skip flag. In an operator local run where the sibling Hub exists, the stack RC gate runs the Hub gate and both E2E modes.

## Outputs

The RC gate writes only local files under `.smoke\stack-rc\stack-rc-<timestamp>\`:

- `stack-rc-report.json`
- `stack-rc-report.md`
- `stack-rc-manifest.json`
- Agent package artifacts under the run artifact directory

Reports contain status, commands run, pass/fail or skipped state, Agent and Hub commits, package versions, artifact path, and safety booleans. They intentionally omit raw logs, raw response bodies, full environment data, Authorization headers, cookies, HMAC signatures, and secret values.

## Contract Coverage

The stack RC baseline checks that Agent and Hub still agree on:

- `POST /v1/events/batch`
- `GET /v1/nodes`
- `GET /v1/summary`
- `GET /v1/services`
- `GET /v1/custom`
- `GET /v1/events/recent`
- `node.snapshot`
- `node.resources.snapshot`
- `service.health.snapshot`
- `custom.snapshot`
- `telemetry.agent.health`
- `docker.containers.snapshot`
- `systemd.units.snapshot`

The local E2E proves the read model through the sibling Hub. Hub release-gate coverage handles duplicate event behavior and recent-history smoke coverage when that gate passes.

## Pass Criteria

- Stack doctor passes.
- Hub release gate passes when the sibling Hub repo is present.
- Agent release gate passes.
- Once-mode Agent to Hub E2E passes.
- Daemon-mode Agent to Hub E2E passes.
- Agent package manifest exists and its forbidden marker scan passes.
- Generated reports pass the local forbidden-marker scan.

Any failure is a local readiness blocker. Fix the minimal local issue, rerun the failing command, and then rerun the full stack RC gate.
