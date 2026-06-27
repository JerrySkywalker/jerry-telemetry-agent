# Security

- Keep `.env` and real secrets out of git.
- `TELEMETRY_NODE_SECRET` is used only for HMAC signing.
- Secret-like environment values are not logged.
- The backend collector never logs, uploads, or persists `access_token`, `refresh_token`, raw `auth.json`, email, account ID, user ID, referral beacon, promo, or the full raw ChatGPT backend response.
- The collector may read `tokens.access_token` from local Codex auth, but it stores only normalized usage percentages, reset times, plan type, credits, spend-control summary, and safe error diagnostics.
- Raw Codex account and session IDs are redacted before fallback upload.
- Payloads that still contain unredacted account or session identifiers are rejected.
- HTTP output sends only the normalized `codex.usage.snapshot` inside the hub envelope.
- Batch output sends only v1 telemetry envelopes under `{ schema_version: "v1", events: [...] }` to Hub `/v1/events/batch`.
- Agent health output sends only safe booleans, counts, timestamps, and string categories inside `telemetry.agent.health`. It records sensitive categories in `raw_omitted_keys` but never includes secret values, raw env, Authorization headers, raw `auth.json`, account ids, or raw backend responses.
- Collector names and event types are allowlisted by the typed registry. Unknown collector names fail closed, and arbitrary shell command collectors are intentionally not supported.
- Event envelopes only accept registry-approved event types: `codex.usage.snapshot`, `telemetry.agent.health`, `node.snapshot`, `node.resources.snapshot`, `service.health.snapshot`, and `custom.snapshot`.
- Local node-info and node-resources collectors do not read Codex auth, browser stores, cookie stores, `.env`, or user directories. Disk summaries use only generic drive or mount labels plus total/free/used percentages.
- Local service-health and custom-json collectors use fixture/static file inputs only. Custom JSON files are limited to 64 KiB, recursively sanitized, and summarized unless explicitly marked safe.
- Local readback tokens are for server-side/local test scripts only. Do not embed static read tokens in browser, mobile, watch, dashboard, or push-notification bundles.
- The non-LAX pilot examples use placeholder-only configuration and default to file output. HTTP upload requires a manually supplied node secret from outside git.
- No OAuth refresh is implemented; Codex CLI owns authentication refresh.

## Repository Guardrails

- Do not commit `.env`, `.env.*`, `auth.json`, local raw usage dumps, or real telemetry secrets.
- Do not commit `access_token`, `refresh_token`, email, account ID, or user ID values in snapshots.
- Use `.env.example` for documented configuration names only.
- Config rendering or deployment gates must stop when required secret values are missing. Missing secret names may be reported; secret values must not be printed.
- Run `scripts/scan-secrets-light.ps1` before opening or updating PRs. This is a lightweight guardrail for obvious mistakes, not a full secret scanner.
- GitHub Actions must not contain production secrets or deploy to production in the current CI-only phase.

## LAX Docker Guardrails

- LAX Docker backend usage mode mounts the host Codex directory read-only.
- The Docker image must not contain `auth.json` or any copied Codex credential material.
- Local smoke scripts write only normalized safe snapshots and must not upload to the telemetry hub.
- Local one-shot batch smokes write only safe batch JSON and may upload only to an explicitly supplied local Hub URL with a manually supplied dev secret.
- LAX production systemd timers remain unchanged until explicit manual approval.
