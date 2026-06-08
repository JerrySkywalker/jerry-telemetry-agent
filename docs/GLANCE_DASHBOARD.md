# Glance Dashboard

Enable the health server to expose dashboard-friendly JSON:

- `GET /api/codex/usage/latest`
- `GET /api/codex/usage/summary`

`/api/codex/usage/summary` is compact and redacted. It includes:

- `ok`, `stale`, `node_id`, `plan_type`
- default limit primary/secondary used and remaining percent
- `reset_after_seconds`, `reset_at_iso`
- additional limits
- credits and spend-control summaries
- `observed_at`
- `last_success_at`

Glance should read these endpoints or the safe snapshot file. It must not parse raw backend responses.

For backend usage, the safe snapshot type is `codex.usage.snapshot`. The default limit appears in `limits` with `scope=default`; model-specific limits, including GPT-5.3-Codex-Spark when present, appear as additional limits.
