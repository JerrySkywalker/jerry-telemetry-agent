# Canary Agent Supervision Options

`scripts/canary-agent-supervision-plan-local.ps1` compares ways to make the retained Agent HTTP canary more durable. It is plan-only and does not touch the live canary.

Option A: keep current container-only canary.

- Lowest change.
- Preserves the currently passing canary.
- Keeps the current restart policy concern.
- Requires external observation and manual recovery.

Option B: Docker restart policy for the canary container.

- Simpler than a wrapper service.
- Mutates Docker runtime in a later goal.
- Requires explicit authorization before any live change.

Option C: systemd wrapper managing the canary container.

- More explicit operational baseline.
- Can expose service status and restart count cleanly.
- Adds moving parts and requires careful scoping.
- Recommended for review before live hardening.

Option D: compose-managed canary stack.

- Cleaner long-term service shape.
- Broader migration.
- Requires compose file, path, backup, and rollback governance.

Default recommendation:

- Do not change the live canary now.
- Keep current HTTP canary running while the design is reviewed.
- Prefer reviewing Option C or Option D before any live hardening goal.
- Do not rename to production yet.
- Do not touch existing LAX Codex runtime.
- Do not expose raw Hub publicly.
