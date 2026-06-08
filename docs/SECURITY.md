# Security

- Keep `.env` and real secrets out of git.
- `TELEMETRY_NODE_SECRET` is used only for HMAC signing.
- Secret-like environment values are not logged.
- Raw Codex account and session IDs are redacted before upload.
- Payloads that still contain unredacted account or session identifiers are rejected.
