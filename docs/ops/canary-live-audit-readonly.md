# Canary Live Audit Readonly

`scripts/canary-live-audit-readonly.ps1` runs a bounded read-only audit of the retained telemetry canary.

Default scope:

- Hub canary service on the Hub host.
- Reverse tunnel canary service on the Hub host.
- Agent HTTP canary container on the Agent host.
- Localhost-only Hub health, read-model, and Agent health/status endpoints.
- Safe file metadata and count checks for active and archived spool.
- Bounded log summaries as counts only.

The script requires explicit operator authorization before live use. It uses SSH only for read-only inspection. It must not deploy, upload files, write production paths, change configs, change secrets, mutate Docker runtime, mutate services, mutate tunnels, or touch spool.

The report outputs are local `.smoke` files:

- `canary-live-audit-summary.md`
- `canary-live-audit-summary.json`
- `hub-live-audit.md`
- `tunnel-live-audit.md`
- `agent-live-audit.md`
- `sample-table.md`
- `marker-scan-report.json`
- `canary-live-audit-checklist.md`

The script does not print raw logs, raw response bodies, private keys, read tokens, node secrets, signed headers, cookies, environment files, webhook URLs, account identifiers, user identifiers, or mail addresses. The Hub readback token is used only server-side for localhost read-model smoke.

Archived spool policy:

- Old HTTP spool archive remains diagnostic evidence.
- Failed-check archive remains diagnostic evidence.
- Do not flush, restore, or delete archived spool automatically.

Operational interpretation:

- A stale prior HTTP error timestamp in Agent state is not by itself a failure when the current error-present flag is false and latest successful send is newer.
- Existing LAX Codex runtime remains outside this canary audit.
- Raw Hub public exposure remains forbidden.
- This canary is not a production rename.

Use the rollback planner when health, tunnel reachability, read model, SQLite integrity, active spool, or marker scan checks fail.
