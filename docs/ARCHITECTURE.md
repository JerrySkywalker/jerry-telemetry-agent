# Architecture

`jerry-telemetry-agent` is a Dockerized node-side collector. It gathers Codex status through a provider, redacts and validates the payload, wraps it in a generic telemetry envelope, signs it with HMAC, uploads it to `jerry-telemetry-hub`, and spools failed uploads for retry.

Core modules:
- providers: collect Codex status from file, host Codex, or future container Codex.
- codex: parse, redact, and validate Codex status.
- telemetry: envelope, HMAC, uploader, state, and spool.
- health: optional local health/status HTTP server.
