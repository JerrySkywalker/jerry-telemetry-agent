# Architecture

`jerry-telemetry-agent` is a Dockerized node-side collector for many telemetry nodes. Its first production profile is the LAX Codex usage node, but that profile is one collector configuration, not the whole product. The primary Codex collector reads local Codex `auth.json`, extracts the ChatGPT-managed access token, calls the ChatGPT backend wham usage endpoint, normalizes the response into a safe `codex.usage.snapshot`, and emits it through configured sinks.

HTTP output wraps normalized snapshots in the existing telemetry envelope, signs the raw JSON body with HMAC, uploads single events to `jerry-telemetry-hub`, and spools failed single-event uploads for retry. The local one-shot and generic server paths can also build safe v1 batches and POST them to Hub `/v1/events/batch`. Raw backend responses are never sent to the hub.

Collector selection is typed and allowlisted by `src/collectors/registry.ts`. Implemented collector names are `codex-backend-usage`, `codex-cli-status-fallback`, `agent-health`, `node-info`, `node-resources`, `service-health`, `http-probe`, `tcp-probe`, `docker-containers`, `systemd-units`, and `custom-json`. Unknown names fail closed during config load. Arbitrary shell command collectors are intentionally not supported.

Nodes are not required to collect Codex usage. A health-only node config can enable only `agent-health`; in that profile `runOnce` skips Codex usage collection and emits only `telemetry.agent.health` through local or approved sinks.

The local one-shot batch path is separate from the LAX daemon path. It can run on Windows without Codex auth, produce fixture or local Windows node telemetry, write a safe batch file, optionally push to a local Hub, and optionally verify readback from `/v1/nodes`, `/v1/summary`, `/v1/services`, and `/v1/custom`.

The server one-shot path builds a Hub-compatible v1 batch from declarative Linux server collectors. The generic server daemon reuses that batch builder in a loop, retries spooled batches before collecting a new batch, writes latest/file outputs, uploads batches through the HMAC batch endpoint when enabled, and spools sanitized failed batches for later retry. Collector failures become safe degraded payloads and agent-health status rather than crashing the whole batch, while invalid config still fails closed.

The generic server daemon is implemented in `src/serverDaemon.ts` and launched by `src/server-agent-daemon.ts` or `scripts/server-agent-daemon.ps1`. It intentionally does not replace the LAX Codex daemon path in `src/main.ts`; the existing Codex single-event spool/retry behavior remains compatible.

Batch spool files use a batch-specific suffix so the Codex single-event spool reader does not treat them as single events. Batch retry is oldest-first. Invalid batch spool files are quarantined, retry failures keep the file for a later interval, and configurable file/byte limits drop oldest batch spool files with safe state reporting.

The local health server keeps the existing `/healthz`, `/status`, and Codex endpoints, and adds generic server summaries at `/api/server/status` and `/api/server/batch/latest`. The latest-batch endpoint returns a safe summary, not raw event payloads.

Core modules:
- collectors/codex: auth lookup, backend usage client, normalizer, fallback adapter.
- collectors/local: fixture and local Windows one-shot collectors.
- collectors/linux: Linux node-info and node-resources helpers.
- collectors/probes: HTTP and TCP probes with timeouts and sanitized outputs.
- collectors/docker: read-only Docker container status from safe CLI formatting.
- collectors/systemd: read-only `systemctl show` unit status for configured units.
- collectors/custom: hardened custom JSON file collector.
- collectors/serverBatch: declarative server batch orchestrator.
- collectors/registry: typed collector allowlist and per-node collector config validation.
- providers: legacy file and host-Codex tmux `/status` fallback.
- codex: parse, redact, and validate Codex status.
- telemetry: envelope, batch, HMAC, uploader, state, and single-event/batch spool.
- sinks: stdout/file output for normalized snapshots and safe server batches.
- health: optional local health/status HTTP server plus Codex and server summary endpoints.
