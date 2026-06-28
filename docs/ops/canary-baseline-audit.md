# Canary Baseline Audit

`scripts/canary-baseline-audit.ps1` turns local canary evidence into a safe audit report. The default mode reads `.smoke` evidence only and does not SSH.

Default command:

```powershell
.\scripts\canary-baseline-audit.ps1
```

Outputs:

- `canary-baseline-audit-summary.md`
- `canary-baseline-audit-summary.json`
- `canary-baseline-checklist.md`

The audit checks:

- Hub canary health evidence.
- Reverse tunnel evidence.
- Agent HTTP canary evidence.
- Extended soak evidence.
- Marker scan evidence.
- Active spool evidence.
- Archived spool preservation.
- Hub read model evidence.
- Raw Hub public exposure boundary.
- LAX Codex runtime untouched boundary.

Live mode is intentionally refused unless a future authorized wrapper provides live read-only status. This prevents an ordinary release gate or CI run from reaching production hosts.

Outstanding canary risks tracked by the audit:

- A stale prior HTTP error timestamp can remain in Agent state. The current last batch error flag and latest successful send timestamp are the operational signal.
- Agent restart policy is not treated as final production hardening.
- Archived spool retention needs an operator decision before deletion or permanent quarantine.

The audit report must contain booleans, counts, paths under `.smoke`, and PASS or FAIL statuses only. It must not include raw logs, raw response bodies, config file contents, private keys, node secrets, read credentials, signatures, cookies, or generated credential values.
