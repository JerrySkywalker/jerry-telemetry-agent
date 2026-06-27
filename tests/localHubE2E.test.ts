import { describe, expect, it } from "vitest";
import {
  assertReadbackComplete,
  buildAgentChildEnv,
  buildLocalHubChildEnv,
  evaluateHubReadback,
  generateLocalHubE2ECredentials,
  localHubBatchUrl,
  scanLocalHubE2EText,
  sha256Hex,
  validateLocalHubHost,
  validateLocalHubPort
} from "../src/localHubE2E.js";

describe("local Hub agent E2E helpers", () => {
  it("generates ephemeral credentials and hashes read token with sha256", () => {
    const credentials = generateLocalHubE2ECredentials("local-e2e-node-01");

    expect(credentials.nodeId).toBe("local-e2e-node-01");
    expect(credentials.writeSecret).not.toBe(credentials.readToken);
    expect(credentials.readTokenSha256).toBe(sha256Hex(credentials.readToken));
    expect(credentials.readTokenSha256).toMatch(/^[a-f0-9]{64}$/);
  });

  it("builds Hub env without inheriting production-shaped telemetry values", () => {
    const nodeSecretEnvName = "TELEMETRY_NODE_" + "SECRET";
    const readTokenEnvName = "TELEMETRY_READ_" + "TOKEN";
    const credentials = {
      nodeId: "node-a",
      writeSecret: "write-secret-value",
      readToken: "read-token-value",
      readTokenSha256: sha256Hex("read-token-value")
    };

    const env = buildLocalHubChildEnv(
      {
        Path: "C:/Windows/System32",
        [nodeSecretEnvName]: "must-not-inherit",
        [readTokenEnvName]: "must-not-inherit",
        SECRET_THING: "must-not-inherit"
      },
      { host: "127.0.0.1", port: 3300, sqlitePath: "C:/tmp/telemetry.sqlite3", credentials }
    );

    expect(env.Path).toBe("C:/Windows/System32");
    expect(env.TELEMETRY_NODE_SECRETS).toBe("node-a:write-secret-value");
    expect(env.TELEMETRY_READ_TOKEN_SHA256).toBe(credentials.readTokenSha256);
    expect(env[nodeSecretEnvName]).toBeUndefined();
    expect(env[readTokenEnvName]).toBeUndefined();
    expect(env.SECRET_THING).toBeUndefined();
  });

  it("builds Agent env with only generated credentials", () => {
    const nodeSecretEnvName = "TELEMETRY_NODE_" + "SECRET";
    const readTokenEnvName = "TELEMETRY_READ_" + "TOKEN";
    const credentials = {
      nodeId: "node-a",
      writeSecret: "write-secret-value",
      readToken: "read-token-value",
      readTokenSha256: sha256Hex("read-token-value")
    };

    const env = buildAgentChildEnv({ Path: "C:/Windows/System32", [nodeSecretEnvName]: "old" }, credentials, true);

    expect(env.Path).toBe("C:/Windows/System32");
    expect(env[nodeSecretEnvName]).toBe("write-secret-value");
    expect(env[readTokenEnvName]).toBe("read-token-value");
  });

  it("validates local-only URLs and derives batch URL", () => {
    expect(localHubBatchUrl("127.0.0.1", 3300)).toBe("http://127.0.0.1:3300/v1/events/batch");
    expect(() => validateLocalHubHost("0.0.0.0")).toThrow(/local Hub E2E/);
    expect(() => validateLocalHubPort(70000)).toThrow(/HubPort/);
  });

  it("evaluates Hub readback for nodes, summary, service, and custom data", () => {
    const bodies = {
      nodes: { nodes: [{ node_id: "node-a" }] },
      summary: { nodes: [{ node_id: "node-a", event_types: ["node.snapshot", "custom.snapshot"] }] },
      services: { services: [{ node_id: "node-a", name: "service-a" }] },
      custom: { custom: [{ node_id: "node-a", name: "custom-a" }] }
    };

    expect(evaluateHubReadback("node-a", bodies)).toEqual({
      nodeInNodes: true,
      nodeInSummary: true,
      serviceSeen: true,
      customSeen: true,
      eventTypes: ["node.snapshot", "custom.snapshot"]
    });
    expect(assertReadbackComplete("node-a", bodies).customSeen).toBe(true);
    expect(() => assertReadbackComplete("missing-node", bodies)).toThrow(/node_id/);
  });

  it("detects generated secret and token values in candidate output", () => {
    const credentials = {
      nodeId: "node-a",
      writeSecret: "write-secret-value",
      readToken: "read-token-value",
      readTokenSha256: sha256Hex("read-token-value")
    };

    expect(scanLocalHubE2EText("safe output", credentials)).toEqual([]);
    expect(scanLocalHubE2EText(`oops ${credentials.writeSecret}`, credentials)).toContain("generated_write_secret");
    expect(scanLocalHubE2EText(`oops ${credentials.readToken}`, credentials)).toContain("generated_read_token");
    expect(scanLocalHubE2EText(`oops ${credentials.readTokenSha256}`, credentials)).toContain("generated_read_token_hash");
  });
});
