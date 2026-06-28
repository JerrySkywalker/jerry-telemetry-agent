# Canary Live Audit Contract

`scripts/canary-live-audit-contract-local.ps1` defines a future read-only live audit contract. The script itself does not SSH, does not run live checks, and does not mutate production or canary runtime.

Allowed future live-audit categories, only after explicit authorization:

- Read-only service active state and safe service metadata.
- Docker container listing with safe fields only.
- Localhost health and status checks.
- Hub read-model status with server-side readback handling.
- SQLite integrity for the canary database.
- File metadata and count checks for state, active spool, and archived spool.
- Bounded log reads for local analysis, with count-only reporting.

Forbidden live-audit behavior:

- Starting, stopping, restarting, enabling, disabling, or editing services.
- Mutating Docker containers, compose stacks, images, volumes, or networks.
- Creating, deleting, restoring, or flushing spool.
- Uploading files.
- Writing production paths.
- Printing secrets, private key material, signatures, cookies, raw request bodies, raw response bodies, or raw logs.

Required report fields:

- Timestamp.
- Target aliases only.
- Service names and container name.
- Status codes.
- Restart counts.
- Spool counts.
- Event type names.
- Marker scan result.
- Skipped checks with reasons.
- Failure recommendation.

Failure handling:

- Do not mutate automatically.
- Record a safe failure summary.
- Recommend rollback, continued observation, or deeper diagnosis.
- Stop if a check would require printing a secret or raw log.
