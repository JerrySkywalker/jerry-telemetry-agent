# Canary Rollback

`scripts/canary-rollback-plan-local.ps1` renders rollback plans only. It does not execute service, Docker, tunnel, file, credential, or spool changes.

Example:

```powershell
.\scripts\canary-rollback-plan-local.ps1 -Mode FileOnlyRollback -OutputDir .smoke\canary-rollback-plan
```

Supported modes:

- `StopHttpCanary`: plan to stop the HTTP-upload canary without starting a replacement.
- `FileOnlyRollback`: plan to return to a file-only canary while preserving diagnostics.
- `FullCanaryStop`: plan to stop Agent, tunnel, and Hub canaries after evidence preservation.

Rollback principles:

- Preserve Agent state, active spool, archived old spool, failed-check archive, and diagnostic reports.
- Do not flush archived spool automatically.
- Do not restore archived spool automatically.
- Do not delete archived spool without a separate retention decision.
- Do not touch the existing LAX Codex runtime.
- Do not modify unrelated Beijing services.
- Do not expose raw Hub publicly during rollback.

Rollback stop conditions:

- The rollback would affect non-canary services.
- State or spool counts are ambiguous.
- Diagnosis appears to require printing a secret or raw log.
- A plan would require changing current LAX Codex runtime.

After a later authorized rollback, verify Hub health if retained, Agent mode, active spool count, tunnel status if retained, marker scan status, and read model behavior. Report summaries only.
