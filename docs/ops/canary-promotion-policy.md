# Canary Promotion Policy

The retained HTTP canary is a stable canary candidate, not a production promotion. Promotion decisions must remain explicit and human-approved.

Recommended policy:

- Keep current canary service names while observation continues.
- Stabilize operations around the retained canary before any production rename.
- Do not add more Agent nodes until the current canary has a longer operations record.
- Do not touch the existing LAX Codex runtime.
- Do not expose raw Hub publicly.
- Keep Hub read credentials server-side only.

Not recommended yet:

- Renaming canary paths and services into production names.
- Replacing or migrating the existing LAX Codex runtime.
- Adding dashboard, mobile, watch, notify, or other consumers.
- Publishing raw Hub behind a public endpoint.
- Flushing stale archived spool into Hub.

Archived spool policy:

- Old HTTP spool archive and failed-check archive are diagnostic evidence.
- Keep them for the operator-approved retention window.
- Inspect metadata only when possible.
- Do not upload stale failed-chain data.
- Delete only after a separate operator authorization.

Credential policy:

- Keep write credentials and readback credentials server-side.
- Do not put read credentials in the Agent daemon unless a specific local readback script requires it.
- Do not put read credentials in frontend, browser, mobile, watch, dashboard, or static clients.
- Rotate or revoke credentials only under a separate authorized goal.

Next authorization choices:

- Continue observation with a read-only canary observation goal.
- Stabilize the current canary baseline with operational hardening.
- Roll back to file-only or stop canaries.
- Plan production promotion later with backup, rollback, naming, and runtime migration decisions stated up front.
