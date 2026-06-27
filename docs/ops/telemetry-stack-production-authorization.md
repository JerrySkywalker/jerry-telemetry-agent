# Telemetry Stack Production Authorization Template

This template is for a future manual deployment approval. Do not fill it with real secrets in ChatGPT, GitHub, or committed files.

## Required Approval Fields

- Target:
- Hub endpoint:
- Node ID:
- Deployment mode:
- File-only canary first:
- HTTP upload canary:
- Rollback trigger:
- Backup confirmed:
- Deployment window:
- Current LAX runtime decision:
- Manual approval sentence:

## Approval Rules

- A stack RC gate pass is required before this template is considered.
- Production deployment remains blocked until the operator gives explicit approval for a specific target and time window.
- Real node secrets must be created and stored outside git.
- A node secret must be unique per node.
- Key rotation must use the configured node key identifier plan.
- Read tokens, if needed for verification, must be handled outside committed files and local reports.
- The health endpoint must remain localhost-bound or private unless a later approved design changes that boundary.
- Rollback must preserve state and secrets unless the operator separately approves removal.

## Manual Approval Sentence Template

Use a clear sentence in a future deployment goal, for example:

```text
I approve deploying the telemetry Agent to <target> using <deployment mode> during <window>, with file-only canary <yes/no>, HTTP upload canary <yes/no>, backup path <path stored outside chat>, rollback trigger <trigger>, and current LAX runtime decision <leave untouched/migrate later>.
```

Do not include real secret values, Authorization headers, cookies, raw request bodies, raw response bodies, account identifiers, user identifiers, or generated credential values in the approval text.
