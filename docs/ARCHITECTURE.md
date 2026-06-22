# Architecture

`jerry-telemetry-agent` is a Dockerized node-side collector for many telemetry nodes. Its first production profile is the LAX Codex usage node, but that profile is one collector configuration, not the whole product. The primary Codex collector reads local Codex `auth.json`, extracts the ChatGPT-managed access token, calls the ChatGPT backend wham usage endpoint, normalizes the response into a safe `codex.usage.snapshot`, and emits it through configured sinks.

HTTP output wraps the normalized snapshot in the existing telemetry envelope, signs it with HMAC, uploads it to `jerry-telemetry-hub`, and spools failed uploads for retry. Raw backend responses are never sent to the hub.

Collector selection is typed and allowlisted by `src/collectors/registry.ts`. Implemented collector names are `codex-backend-usage`, `codex-cli-status-fallback`, and `agent-health`. Unknown names fail closed during config load. Arbitrary shell command collectors are intentionally not supported.

Core modules:
- collectors/codex: auth lookup, backend usage client, normalizer, fallback adapter.
- collectors/registry: typed collector allowlist and per-node collector config validation.
- providers: legacy file and host-Codex tmux `/status` fallback.
- codex: parse, redact, and validate Codex status.
- telemetry: envelope, HMAC, uploader, state, and spool.
- sinks: stdout/file output for normalized snapshots.
- health: optional local health/status HTTP server plus dashboard JSON endpoints.
