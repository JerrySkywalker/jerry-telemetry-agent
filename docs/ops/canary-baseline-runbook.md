# Canary Baseline Runbook

This runbook covers the retained telemetry canary baseline only. It does not promote the canary to production service names, deploy additional nodes, or modify the existing LAX Codex runtime.

Current baseline shape:

- Hub canary: private receiver and read model on the canary host.
- Reverse tunnel canary: private localhost path from the Agent host to the Hub canary.
- Agent HTTP canary: generic server telemetry producer using the localhost tunnel endpoint.
- Archived diagnostic spool: preserved evidence, not active telemetry.

Daily checks:

- Hub canary health returns success on its localhost endpoint.
- Hub read model sees the canary node, service, custom state, and recent events.
- Reverse tunnel is active, reachable from the Agent host localhost bind, and has no non-local listener.
- Agent canary health and status endpoints return success.
- Agent pending active spool remains zero.
- Latest successful send age stays within the approved threshold.
- Current last batch error flag remains false.
- Logs are summarized by counts only; raw logs are not copied into reports.

Weekly checks:

- Hub SQLite integrity is ok.
- Hub backup readiness is confirmed.
- Retention policy remains documented and dry-run safe.
- Credential file permissions are checked without printing values.
- Marker scan passes for generated local reports.

Thresholds:

- Pending active spool above zero for more than the approved interval requires operator review.
- Latest successful send older than ten minutes requires diagnosis.
- Any restart count increase on Hub, tunnel, or Agent requires a canary observation report.
- SQLite integrity failure requires stopping promotion work and planning rollback.
- Any non-local raw Hub listener is a stop condition.

Boundaries:

- Do not rename canary paths or services to production names without a separate authorization.
- Do not touch the existing LAX Codex runtime from canary operations.
- Do not expose raw Hub publicly.
- Do not embed read credentials in browser, mobile, watch, dashboard, or static clients.
- Do not flush, restore, or delete archived spool automatically.
- Do not paste secrets into ChatGPT or generated reports.

Evidence directories:

- `.smoke/canary-stabilize-*`
- `.smoke/http-canary-observe-03-*`
- `.smoke/canary-promote-plan-*`
- `.smoke/canary-baseline-audit-*`

The repository-owned evidence check is:

```powershell
.\scripts\canary-baseline-audit.ps1
```

The repository-owned local gate is:

```powershell
.\scripts\canary-baseline-gate-local.ps1
```

Human approval remains required for any live operation that would change services, containers, tunnels, configs, credentials, or spool.
