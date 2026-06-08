import http from "node:http";
import { describe, expect, it } from "vitest";
import { uploadEvent } from "../src/telemetry/uploader.js";
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
