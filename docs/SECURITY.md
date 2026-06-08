# Security

- Keep `.env` and real secrets out of git.
- `TELEMETRY_NODE_SECRET` is used only for HMAC signing.
- Secret-like environment values are not logged.
- The backend collector never logs, uploads, or persists `access_token`, `refresh_token`, raw `auth.json`, email, account ID, user ID, referral beacon, promo, or the full raw ChatGPT backend response.
- Raw Codex account and session IDs are redacted before fallback upload.
- Payloads that still contain unredacted account or session identifiers are rejected.
- HTTP output sends only the normalized `codex.usage.snapshot` inside the hub envelope.
- No OAuth refresh is implemented; Codex CLI owns authentication refresh.

## Repository Guardrails

- Do not commit `.env`, `.env.*`, `auth.json`, local raw usage dumps, or real telemetry secrets.
- Do not commit `access_token`, `refresh_token`, email, account ID, or user ID values in snapshots.
- Use `.env.example` for documented configuration names only.
- Run `scripts/scan-secrets-light.ps1` before opening or updating PRs. This is a lightweight guardrail for obvious mistakes, not a full secret scanner.
- GitHub Actions must not contain production secrets or deploy to production in the current CI-only phase.
