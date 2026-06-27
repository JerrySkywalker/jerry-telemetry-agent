import http from "node:http";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { buildServerTelemetryBatch } from "../src/collectors/serverBatch.js";
import { runServerOnce } from "../src/serverOnce.js";
import { findForbiddenTelemetryMarkers } from "../src/telemetry/forbiddenMarkers.js";
import { tempDir } from "./helpers.js";

describe("server telemetry batch", () => {
  it("builds a v1 batch with server event types", async () => {
    const batch = await buildServerTelemetryBatch({
      node_id: "example-linux-01",
      hostname: "example-linux-01",
      region: "local",
      role: "general-linux-node",
      provider: "local",
      collectors: [
        { name: "node-info", enabled: true },
        { name: "node-resources", enabled: true },
        { name: "http-probe", enabled: true, targets: [{ name: "down", url: "http://127.0.0.1:1/healthz", timeout_ms: 50 }] },
        { name: "tcp-probe", enabled: true, targets: [{ name: "closed", host: "127.0.0.1", port: 1, timeout_ms: 50 }] },
        { name: "custom-json", enabled: true, files: [] },
        { name: "agent-health", enabled: true }
      ]
    }, { capturedAt: "2026-06-08T00:00:00.000Z" });

    expect(batch.schema_version).toBe("v1");
    expect(batch.events.map((event) => event.event_type)).toEqual([
      "node.snapshot",
      "node.resources.snapshot",
      "service.health.snapshot",
      "service.health.snapshot",
      "custom.snapshot",
      "telemetry.agent.health"
    ]);
    expect(findForbiddenTelemetryMarkers(batch)).toEqual([]);
  });

  it("server once writes a safe file and uploads to a mock hub", async () => {
    const dir = await tempDir();
    const configPath = path.join(dir, "node.json");
    const outFile = path.join(dir, "server.batch.safe.json");
    await writeFile(
      configPath,
      JSON.stringify({
        node_id: "example-linux-01",
        hostname: "example-linux-01",
        region: "local",
        role: "general-linux-node",
        provider: "local",
        collectors: [
          { name: "node-info", enabled: true },
          { name: "node-resources", enabled: true },
          { name: "custom-json", enabled: true, files: [] },
          { name: "agent-health", enabled: true }
        ]
      })
    );

    let postPath = "";
    const server = http.createServer((req, res) => {
      postPath = req.url ?? "";
      req.resume();
      res.writeHead(202, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing server address");

    const result = await runServerOnce({
      configPath,
      output: "Push",
      outFile,
      hubUrl: `http://127.0.0.1:${address.port}`,
      writeSecret: "dev-secret"
    });
    server.close();

    expect(result).toMatchObject({ node_id: "example-linux-01", upload: "ok", forbidden_markers_found: false });
    expect(postPath).toBe("/v1/events/batch");
    expect(JSON.parse(await readFile(outFile, "utf8"))).toMatchObject({ schema_version: "v1" });
  });
});
