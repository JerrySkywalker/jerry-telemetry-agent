import http from "node:http";
import crypto from "node:crypto";
import { describe, expect, it } from "vitest";
import { resolveBatchHubUrl, uploadBatch, uploadEvent } from "../src/telemetry/uploader.js";
import { testConfig } from "./helpers.js";

describe("uploadEvent", () => {
  it("posts signed telemetry body", async () => {
    let seenHeaders: http.IncomingHttpHeaders = {};
    let seenBody = "";
    const server = http.createServer((req, res) => {
      seenHeaders = req.headers;
      req.on("data", (chunk) => {
        seenBody += chunk;
      });
      req.on("end", () => {
        res.writeHead(204);
        res.end();
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing server address");

    await uploadEvent(testConfig({ hubUrl: `http://127.0.0.1:${address.port}/telemetry` }), { ok: true });
    server.close();

    expect(seenBody).toBe("{\"ok\":true}");
    expect(seenHeaders["x-telemetry-node"]).toBe("us-lax-pro-01");
    expect(seenHeaders["x-telemetry-signature"]).toBeTypeOf("string");
  });

  it("treats non-2xx as failure", async () => {
    const server = http.createServer((_req, res) => {
      res.writeHead(500);
      res.end("nope");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing server address");

    await expect(uploadEvent(testConfig({ hubUrl: `http://127.0.0.1:${address.port}/telemetry` }), { ok: true })).rejects.toThrow(/HTTP 500/);
    server.close();
  });
});

describe("uploadBatch", () => {
  it("derives the batch endpoint from TELEMETRY_HUB_URL", () => {
    expect(resolveBatchHubUrl({ hubUrl: "http://127.0.0.1:3000/v1/events" })).toBe("http://127.0.0.1:3000/v1/events/batch");
  });

  it("fails safely when no batch endpoint can be derived", () => {
    expect(() => resolveBatchHubUrl({ hubUrl: "http://127.0.0.1:3000/custom" })).toThrow(/TELEMETRY_HUB_BATCH_URL/);
  });

  it("posts a signed raw batch body and optional key id", async () => {
    let seenHeaders: http.IncomingHttpHeaders = {};
    let seenBody = "";
    const server = http.createServer((req, res) => {
      seenHeaders = req.headers;
      req.on("data", (chunk) => {
        seenBody += chunk;
      });
      req.on("end", () => {
        res.writeHead(202);
        res.end(JSON.stringify({ ok: true }));
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing server address");

    await uploadBatch(
      testConfig({
        hubUrl: `http://127.0.0.1:${address.port}/v1/events`,
        nodeKeyId: "dev-key-1"
      }),
      { schema_version: "v1", events: [{ ok: true }] }
    );
    server.close();

    const timestamp = String(seenHeaders["x-telemetry-timestamp"]);
    const nonce = String(seenHeaders["x-telemetry-nonce"]);
    const expected = crypto.createHmac("sha256", "test-secret").update(`${timestamp}.${nonce}.${seenBody}`).digest("hex");
    expect(seenBody).toBe("{\"schema_version\":\"v1\",\"events\":[{\"ok\":true}]}");
    expect(seenHeaders["x-telemetry-key-id"]).toBe("dev-key-1");
    expect(seenHeaders["x-telemetry-signature"]).toBe(expected);
  });

  it("omits key id when unset and hides failure bodies", async () => {
    let seenHeaders: http.IncomingHttpHeaders = {};
    const server = http.createServer((req, res) => {
      seenHeaders = req.headers;
      res.writeHead(400);
      res.end("raw sensitive body");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing server address");

    await expect(
      uploadBatch(testConfig({ hubUrl: `http://127.0.0.1:${address.port}/v1/events` }), { schema_version: "v1", events: [] })
    ).rejects.toThrow("Telemetry upload failed with HTTP 400");
    server.close();

    expect(seenHeaders["x-telemetry-key-id"]).toBeUndefined();
  });
});
