import { describe, expect, it } from "vitest";
import { buildEnvelope, stablePayloadHash } from "../src/telemetry/envelope.js";
import { testConfig } from "./helpers.js";

describe("envelope", () => {
  it("builds codex.status v1 envelope", () => {
    const envelope = buildEnvelope(testConfig(), { status: "ok" }, "2026-06-08T00:00:00.000Z");
    expect(envelope).toMatchObject({
      schema_version: "v1",
      event_type: "codex.status",
      source: {
        node_id: "us-lax-pro-01",
        hostname: "novix-lax-01",
        region: "us-lax",
        collector: "codex-status"
      },
      captured_at: "2026-06-08T00:00:00.000Z",
      payload: { status: "ok" }
    });
  });

  it("hashes object keys stably", () => {
    expect(stablePayloadHash({ b: 2, a: 1 })).toBe(stablePayloadHash({ a: 1, b: 2 }));
  });
});
