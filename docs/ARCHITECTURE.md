# Architecture

`jerry-telemetry-agent` is a Dockerized node-side collector for many telemetry nodes. Its first production profile is the LAX Codex usage node, but that profile is one collector configuration, not the whole product. The primary Codex collector reads local Codex `auth.json`, extracts the ChatGPT-managed access token, calls the ChatGPT backend wham usage endpoint, normalizes the response into a safe `codex.usage.snapshot`, and emits it through configured sinks.

HTTP output wraps normalized snapshots in the existing telemetry envelope, signs the raw JSON body with HMAC, uploads single events to `jerry-telemetry-hub`, and spools failed single-event uploads for retry. The local one-shot path can also build a safe v1 batch and POST it to Hub `/v1/events/batch`. Raw backend responses are never sent to the hub.

Collector selection is typed and allowlisted by `src/collectors/registry.ts`. Implemented collector names are `codex-backend-usage`, `codex-cli-status-fallback`, `agent-health`, `node-info`, `node-resources`, `service-health`, and `custom-json`. Unknown names fail closed during config load. Arbitrary shell command collectors are intentionally not supported.

Nodes are not required to collect Codex usage. A health-only node config can enable only `agent-health`; in that profile `runOnce` skips Codex usage collection and emits only `telemetry.agent.health` through local or approved sinks.

The local one-shot batch path is separate from the LAX daemon path. It can run on Windows without Codex auth, produce fixture or local Windows node telemetry, write a safe batch file, optionally push to a local Hub, and optionally verify readback from `/v1/nodes`, `/v1/summary`, `/v1/services`, and `/v1/custom`.

Core modules:
- collectors/codex: auth lookup, backend usage client, normalizer, fallback adapter.
- collectors/local: node-info, node-resources, service-health fixture/static data, and custom-json fixture/file data.
- collectors/registry: typed collector allowlist and per-node collector config validation.
- providers: legacy file and host-Codex tmux `/status` fallback.
- codex: parse, redact, and validate Codex status.
- telemetry: envelope, batch, HMAC, uploader, state, and spool.
- sinks: stdout/file output for normalized snapshots.
- health: optional local health/status HTTP server plus dashboard JSON endpoints.
