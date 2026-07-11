# Message Gateway readiness collection

The optional `message-gateway-readiness` collector fetches only the local
`/v1/telemetry/readiness` contract on a loopback URL. It has a maximum two
second timeout and emits `message.gateway.readiness` through the existing
signed batch uploader.

The collector forwards a fixed allowlist from
`jerry.message-gateway.readiness.v1`; it strips unknown fields and never emits
the target URL, hostname, message content, credentials, or raw errors. A
timeout, non-2xx response, malformed document, or unsupported version emits
bounded `unavailable` evidence and does not fail the surrounding batch.

See `deploy/examples/message-gateway-readiness.node.json`. The target is
disabled by default and must remain a local host-only probe.
