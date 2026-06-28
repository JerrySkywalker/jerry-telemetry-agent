# Canary Stabilization To Production Boundary

The retained HTTP canary is a canary baseline, not a production deployment or production rename.

What stabilization may include after explicit authorization:

- Better service supervision for the canary Agent runtime.
- More formal observation cadence.
- Backup and SQLite integrity cadence for Hub canary.
- Read-model smoke cadence.
- Tunnel reachability checks.
- Rollback readiness checks.

What stabilization does not include:

- Renaming canary services or paths to production.
- Migrating or replacing existing LAX Codex runtime.
- Adding dashboard, mobile, watch, notify, or public consumers.
- Exposing raw Hub publicly.
- Flushing stale archived spool into Hub.
- Rotating or generating production credentials.

Promotion requires a separate plan with:

- Target service names.
- Backup path.
- Rollback sequence.
- Downtime or no-downtime decision.
- Credential lifecycle decision.
- Archived spool retention decision.
- Explicit operator authorization.

Until that exists, the operational stance is:

- Keep canary names.
- Keep archived spool preserved.
- Treat stale prior HTTP error timestamp as historical if current error flag is false and successful sends are newer.
- Keep LAX Codex runtime untouched.
- Keep raw Hub private.
