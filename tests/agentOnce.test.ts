import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { runAgentOnce } from "../src/localOnce.js";
import { tempDir } from "./helpers.js";

describe("agent one-shot runner", () => {
  it("writes a safe fixture batch in file-only mode", async () => {
    const dir = await tempDir();
    const outFile = path.join(dir, "fixture.batch.safe.json");

    const result = await runAgentOnce({
      mode: "Fixture",
      output: "FileOnly",
      nodeId: "local-win-dev-01",
      region: "local",
      role: "dev-node",
      provider: "local",
      outFile,
      capturedAt: "2026-06-08T00:00:00.000Z"
    });

    const batchText = await readFile(outFile, "utf8");
    expect(result).toMatchObject({
      node_id: "local-win-dev-01",
      events_count: 5,
      forbidden_markers_found: false,
      upload: "skipped",
      readback: "skipped"
    });
    expect(JSON.parse(batchText)).toMatchObject({ schema_version: "v1" });
    expect(batchText).not.toContain("auth.json");
  });

  it("pushes a batch to a local mock hub and verifies readback", async () => {
    const dir = await tempDir();
    const outFile = path.join(dir, "push.batch.safe.json");
    let postPath = "";
    let postBody = "";
    let authHeaderSeen = false;

    const server = http.createServer((req, res) => {
      if (req.method === "POST") {
        postPath = req.url ?? "";
        req.on("data", (chunk) => {
          postBody += chunk;
        });
        req.on("end", () => {
          res.writeHead(202, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: true }));
        });
        return;
      }

      if (req.url === "/v1/nodes" || req.url === "/v1/summary" || req.url === "/v1/services" || req.url === "/v1/custom") {
        authHeaderSeen = Boolean(req.headers.authorization);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, nodes: [{ node_id: "sample-node" }] }));
        return;
      }

      res.writeHead(404);
      res.end();
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing server address");

    const result = await runAgentOnce({
      mode: "Fixture",
      output: "Push",
      nodeId: "sample-node",
      region: "local",
      role: "dev-node",
      provider: "local",
      hubUrl: `http://127.0.0.1:${address.port}`,
      writeSecret: "dev-secret",
      readToken: "dev-read-token",
      keyId: "dev-key",
      outFile,
      capturedAt: "2026-06-08T00:00:00.000Z"
    });
    server.close();

    expect(result).toMatchObject({
      upload: "ok",
      readback: "checked",
      readback_node_seen: true
    });
    expect(postPath).toBe("/v1/events/batch");
    expect(JSON.parse(postBody)).toMatchObject({ schema_version: "v1" });
    expect(authHeaderSeen).toBe(true);
  });

  it("fails push mode safely when readback is required but no read token is supplied", async () => {
    const dir = await tempDir();
    const server = http.createServer((_req, res) => {
      res.writeHead(204);
      res.end();
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing server address");

    await expect(
      runAgentOnce({
        mode: "Fixture",
        output: "Push",
        nodeId: "sample-node",
        region: "local",
        role: "dev-node",
        provider: "local",
        hubUrl: `http://127.0.0.1:${address.port}`,
        writeSecret: "dev-secret",
        outFile: path.join(dir, "push.batch.safe.json")
      })
    ).rejects.toThrow("Readback requires ReadToken or SkipReadback");
    server.close();
  });
});
