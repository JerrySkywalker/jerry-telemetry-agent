# Canary Operator Reporting

`scripts/canary-report-summarize-local.ps1` reads local `.smoke` evidence and writes a compact handoff for operator review.

It reads the latest available summaries for:

- live read-only audit
- soak observation
- service hardening apply evidence
- baseline audit
- promotion plan

Outputs:

- `canary-operator-summary.md`
- `canary-operator-summary.json`

This summarizer is evidence-only. It does not SSH, mutate production, inspect raw logs, read environment files, read tokens, or read raw response bodies.

Use it after:

- a live read-only audit
- a short or extended soak
- a service-hardening apply goal
- a canary baseline audit

The report is designed for handoff. It should include status, paths, counts, timestamps, and safety booleans only.

Reporting boundaries:

- No production rename.
- No dashboard, mobile, watch, or notify integration.
- No LAX Codex runtime migration.
- No raw Hub public exposure.
- No archived spool flush, restore, or deletion.

If the report shows missing or failed evidence, the next operator decision is to keep observing, render a rollback plan, or authorize a separate remediation goal.
