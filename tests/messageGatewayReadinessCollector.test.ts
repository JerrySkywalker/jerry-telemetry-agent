import { describe, expect, it } from "vitest";
import { collectMessageGatewayReadiness } from "../src/collectors/messageGatewayReadiness.js";
import { parseDeclarativeNodeConfig } from "../src/collectors/registry.js";

const observedAt = "2026-07-11T00:00:00.000Z";

describe("Message Gateway readiness collector", () => {
  it("normalizes the allowlisted readiness contract and discards unknown fields", async () => {
    const result = await collectMessageGatewayReadiness(
      { url: "http://127.0.0.1:3094/v1/telemetry/readiness" },
      observedAt,
      async () => ({ ok: true, json: async () => ({
        schema_version: "jerry.message-gateway.readiness.v1",
        service_id: "jerry-message-gateway",
        observed_at: observedAt,
        status: "healthy",
        process_reachability: "reachable",
        dependencies: { configuration: "ready", message_store: "ready", delivery_path: "ready" },
        last_success_at: observedAt,
        failure_class: "none",
        source: "gateway_runtime",
        freshness_ttl_seconds: 300,
        version: "0.13.0",
        ignored_secret: "must-not-propagate"
      }) }) as Response
    );
    expect(result).toMatchObject({ status: "healthy", source: "telemetry_agent_local_probe", version: "0.13.0" });
    expect(JSON.stringify(result)).not.toContain("ignored_secret");
    expect(JSON.stringify(result)).not.toContain("must-not-propagate");
  });

  it.each([
    [async () => { throw new Error("connection unavailable"); }, "endpoint_unreachable"],
    [async () => ({ ok: true, json: async () => ({ schema_version: "unsupported" }) }) as Response, "invalid_contract"]
  ])("emits bounded unavailable evidence when the local probe cannot provide a valid contract", async (fetchImpl, failureClass) => {
    const result = await collectMessageGatewayReadiness({ url: "http://127.0.0.1:3094/v1/telemetry/readiness" }, observedAt, fetchImpl as typeof fetch);
    expect(result).toMatchObject({ status: "unavailable", failure_class: failureClass, source: "telemetry_agent_local_probe" });
    expect(JSON.stringify(result)).not.toContain("connection unavailable");
  });

  it("requires a loopback target and a bounded timeout", () => {
    expect(() => parseDeclarativeNodeConfig({ collectors: [{ name: "message-gateway-readiness", enabled: true, target: { url: "http://example.test/ready" } }] })).toThrow();
    expect(() => parseDeclarativeNodeConfig({ collectors: [{ name: "message-gateway-readiness", enabled: true, target: { url: "http://127.0.0.1:3094/ready", timeout_ms: 2001 } }] })).toThrow();
  });
});
