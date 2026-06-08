import crypto from "node:crypto";
import { describe, expect, it } from "vitest";
import { signTelemetryBody } from "../src/telemetry/hmac.js";

describe("signTelemetryBody", () => {
  it("signs timestamp.nonce.rawBody using sha256 HMAC", () => {
    const headers = signTelemetryBody("node-1", "secret", "{\"ok\":true}", "2026-06-08T00:00:00.000Z", "nonce-1");
    const expected = crypto.createHmac("sha256", "secret").update("2026-06-08T00:00:00.000Z.nonce-1.{\"ok\":true}").digest("hex");

    expect(headers["X-Telemetry-Node"]).toBe("node-1");
    expect(headers["X-Telemetry-Signature"]).toBe(expected);
  });
});
