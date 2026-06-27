import { describe, expect, it } from "vitest";
import { buildEnvelope, buildTelemetryBatch, buildTelemetryEnvelope, stablePayloadHash } from "../src/telemetry/envelope.js";
import { testConfig } from "./helpers.js";

describe("envelope", () => {
  it("builds a registry-backed v1 envelope", () => {
    const envelope = buildEnvelope(testConfig(), { status: "ok" }, "2026-06-08T00:00:00.000Z");
    expect(envelope).toMatchObject({
      schema_version: "v1",
      event_type: "codex.usage.snapshot",
      source: {
        node_id: "us-lax-pro-01",
        hostname: "novix-lax-01",
        region: "us-lax",
        collector: "codex-backend-usage"
      },
      captured_at: "2026-06-08T00:00:00.000Z",
      payload: { status: "ok" }
    });
  });

  it("rejects payload event types outside the registry allowlist", () => {
    expect(() => buildEnvelope(testConfig(), { type: "custom.shell.output" })).toThrow(/Unsupported telemetry event type/);
  });

  it("builds generic v1 batches", () => {
    const event = buildTelemetryEnvelope(
      { node_id: "local-win-dev-01", hostname: "local-win-dev-01", region: "local", collector: "node-info" },
      "node.snapshot",
      { node_id: "local-win-dev-01" },
      "2026-06-08T00:00:00.000Z"
    );

    expect(buildTelemetryBatch([event])).toEqual({
      schema_version: "v1",
      events: [event]
    });
  });

  it("hashes object keys stably", () => {
    expect(stablePayloadHash({ b: 2, a: 1 })).toBe(stablePayloadHash({ a: 1, b: 2 }));
  });
});
