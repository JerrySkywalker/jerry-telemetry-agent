# Canary Service Baseline Hardening

This document describes plan-only hardening for the retained telemetry canary. It does not authorize production rename, deployment, server mutation, service restart, Docker runtime changes, credential rotation, or spool changes.

Current baseline:

- Hub canary receives HMAC batch telemetry and provides private read-model verification.
- Reverse tunnel canary keeps the Hub canary private while giving the Agent canary a localhost upload path.
- Agent HTTP canary uploads through the localhost tunnel endpoint.
- Archived diagnostic spool remains preserved and is not active telemetry.

Known operational concerns:

- Agent canary container restart policy is currently reported as `no`.
- Reverse tunnel has passed soak observation, but it should remain explicitly observed before any promotion.
- Agent state can retain a stale prior HTTP error timestamp. Current error-present flags and latest successful send timestamp are the operational signal.

Repository-owned planning command:

```powershell
.\scripts\canary-service-baseline-plan-local.ps1
```

The plan covers:

- Hub canary service baseline.
- Reverse tunnel service baseline.
- Agent HTTP canary runtime baseline.
- Whether the Agent canary stays container-only or later receives supervised service management.
- Restart policy recommendation.
- Health, read-model, backup, SQLite integrity, tunnel reachability, and spool check cadence.
- Count-only log summary policy.
- Archived spool retention.
- LAX Codex untouched boundary.
- Raw Hub public exposure forbidden boundary.

Hard boundaries:

- Do not rename canary services or paths to production names in this planning phase.
- Do not modify existing LAX Codex runtime.
- Do not expose raw Hub publicly.
- Do not integrate dashboard, mobile, watch, notify, or other consumers.
- Do not flush archived spool automatically.
- Do not flush, restore, or delete archived spool automatically.
- Do not make live service changes without explicit authorization.
