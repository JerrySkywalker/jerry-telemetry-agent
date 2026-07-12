import http from "node:http";
import net from "node:net";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { runServerDaemon, runServerDaemonIteration, retrySpooledBatches } from "../src/serverDaemon.js";
import { closeHealthServer, startHealthServer, waitForHealthServerListening } from "../src/health/server.js";
import { countSpooledBatches } from "../src/telemetry/spool.js";
import { readState } from "../src/telemetry/state.js";
import { findForbiddenTelemetryMarkers } from "../src/telemetry/forbiddenMarkers.js";
import { tempDir, testConfig } from "./helpers.js";
import type { Config } from "../src/config.js";

describe("server daemon", () => {
  it("runs bounded file-only iterations and updates safe state", async () => {
    const { config } = await fixtureConfig(["file"]);

    const result = await runServerDaemon(config, { maxIterations: 2, intervalMs: 1 });

    expect(result).toEqual({ iterations: 2, stopped: "max_iterations" });
    const batch = JSON.parse(await readFile(config.serverBatchLatestFile, "utf8"));
    const state = await readState(config.statePath);
    expect(batch.schema_version).toBe("v1");
    expect(batch.events.length).toBeGreaterThan(0);
    expect(state).toMatchObject({
      daemonMode: "server",
      nodeId: "example-linux-01",
      lastServerBatchEventsCount: batch.events.length,
      pendingBatchSpoolCount: 0
    });
    expect(JSON.stringify(state)).not.toContain("payload");
    expect(findForbiddenTelemetryMarkers(state)).toEqual([]);
  });

  it("accepts a UTF-8 BOM on the protected server node config", async () => {
    const { config } = await fixtureConfig(["file"]);
    const raw = await readFile(config.nodeConfigPath, "utf8");
    await writeFile(config.nodeConfigPath, `\uFEFF${raw}`);

    await expect(runServerDaemon(config, { maxIterations: 1 })).resolves.toMatchObject({ iterations: 1 });
  });

  it("spools a sanitized batch when upload fails", async () => {
    const server = http.createServer((_req, res) => {
      res.writeHead(500);
      res.end("raw backend body");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing address");
    const { config, nodeConfig } = await fixtureConfig(["file", "http"], { hubUrl: `http://127.0.0.1:${address.port}/v1/events`, nodeSecret: "test-secret" });

    const result = await runServerDaemonIteration(config, nodeConfig);
    await closeServer(server);

    expect(result.upload).toBe("spooled");
    expect(await countSpooledBatches(config.spoolDir)).toBe(1);
    const state = await readState(config.statePath);
    expect(state.lastServerBatchError).toBe("Telemetry upload failed with HTTP 500");
    expect(JSON.stringify(state)).not.toContain("raw backend body");
  });

  it("retries spooled batches before the next new batch and removes them on success", async () => {
    let calls = 0;
    const server = http.createServer((_req, res) => {
      calls += 1;
      res.writeHead(calls === 1 ? 500 : 202, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing address");
    const { config, nodeConfig } = await fixtureConfig(["file", "http"], { hubUrl: `http://127.0.0.1:${address.port}/v1/events`, nodeSecret: "test-secret" });

    await runServerDaemonIteration(config, nodeConfig);
    expect(await countSpooledBatches(config.spoolDir)).toBe(1);
    const result = await runServerDaemonIteration(config, nodeConfig);
    await closeServer(server);

    expect(result.retry).toMatchObject({ attempted: 1, sent: 1, kept: 0 });
    expect(await countSpooledBatches(config.spoolDir)).toBe(0);
  });

  it("keeps spooled batches on retry failure", async () => {
    const server = http.createServer((_req, res) => {
      res.writeHead(503);
      res.end("unavailable");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing address");
    const { config, nodeConfig } = await fixtureConfig(["file", "http"], { hubUrl: `http://127.0.0.1:${address.port}/v1/events`, nodeSecret: "test-secret" });

    await runServerDaemonIteration(config, nodeConfig);
    const retry = await retrySpooledBatches(config);
    await closeServer(server);

    expect(retry).toMatchObject({ attempted: 1, sent: 0, kept: 1 });
    expect(await countSpooledBatches(config.spoolDir)).toBe(1);
  });

  it("quarantines invalid batch spool files during retry", async () => {
    const server = http.createServer((_req, res) => {
      res.writeHead(202);
      res.end("{}");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing address");
    const { config } = await fixtureConfig(["http"], { hubUrl: `http://127.0.0.1:${address.port}/v1/events`, nodeSecret: "test-secret" });
    await mkdir(config.spoolDir, { recursive: true });
    const badFile = path.join(config.spoolDir, "bad.batch.json");
    await writeFile(badFile, "{bad");

    const retry = await retrySpooledBatches(config);
    await closeServer(server);

    expect(retry).toMatchObject({ attempted: 1, quarantined: 1 });
    expect(await countSpooledBatches(config.spoolDir)).toBe(0);
    await expect(readFile(`${badFile}.bad`, "utf8")).resolves.toContain("{bad");
  });

  it("fails fast with a safe message for invalid upload config", async () => {
    const { config, nodeConfig } = await fixtureConfig(["http"], { nodeSecret: "" });

    await expect(runServerDaemonIteration(config, nodeConfig)).rejects.toThrow("TELEMETRY_NODE_SECRET");
  });

  it("serves safe server health and latest batch summaries", async () => {
    const { config, nodeConfig } = await fixtureConfig(["file"], { healthHost: "127.0.0.1", healthPort: 0 });
    await runServerDaemonIteration(config, nodeConfig);
    await writeFile(config.agentHealthOutputFile, JSON.stringify({
      observed_at: "2026-07-12T00:00:00.000Z",
      node: { id: "private-node", hostname: "private-host" },
      agent: { version: "fixture-version" },
      status: { ok: false, degraded: true, message: "raw private error" },
      outputs: { pending_spool_count: 2, last_http_error_at: "2026-07-12T00:00:00.000Z", output_file: config.serverBatchOutputFile }
    }));
    const server = startHealthServer(config);
    await new Promise<void>((resolve) => server.once("listening", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing address");

    const status = await fetchJson(`http://127.0.0.1:${address.port}/api/server/status`);
    const latest = await fetchJson(`http://127.0.0.1:${address.port}/api/server/batch/latest`);
    const health = await fetchJson(`http://127.0.0.1:${address.port}/healthz`);
    const agentHealth = await fetchJson(`http://127.0.0.1:${address.port}/api/agent/health/latest`);
    await closeServer(server);

    expect(status).toMatchObject({ daemon_mode: "server", pending_batch_spool_count: 0, last_batch_error_present: false });
    expect(latest).toMatchObject({ schema_version: "v1", payloads_included: false, forbidden_markers_found: false });
    expect(agentHealth).toMatchObject({ ok: false, degraded: true, pending_spool_count: 2, last_http_error_present: true, output_allowlist_version: "jerry.agent.health.v1" });
    const diagnosticText = JSON.stringify({ status, latest, health, agentHealth });
    expect(diagnosticText).not.toContain("\"payload\":");
    for (const forbidden of ["private-node", "private-host", "raw private error", config.serverBatchOutputFile, "node_id", "hostname", "last_batch_file", "last_error\""]) {
      expect(diagnosticText).not.toContain(forbidden);
    }
    expect(findForbiddenTelemetryMarkers({ status, latest, health, agentHealth })).toEqual([]);
  });

  it("bounds health shutdown when a client leaves an incomplete request open", async () => {
    const { config } = await fixtureConfig(["file"], { healthHost: "127.0.0.1", healthPort: 0 });
    const server = startHealthServer(config);
    await waitForHealthServerListening(server);
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing address");
    const socket = await new Promise<net.Socket>((resolve, reject) => {
      const onError = (error: Error) => reject(error);
      const candidate = net.createConnection({ host: "127.0.0.1", port: address.port }, () => {
        candidate.off("error", onError);
        resolve(candidate);
      });
      candidate.once("error", onError);
    });
    socket.write("GET /healthz HTTP/1.1\r\nHost: fixture\r\n");

    await expect(closeHealthServer(server, 10)).resolves.toBeUndefined();

    expect(server.listening).toBe(false);
    socket.destroy();
  });
});

async function fixtureConfig(outputModes: Config["outputModes"], overrides: Partial<Config> = {}) {
  const dir = await tempDir();
  const nodeConfigPath = path.join(dir, "node.json");
  const nodeConfig = {
    node_id: "example-linux-01",
    hostname: "example-linux-01",
    region: "local",
    role: "general-linux-node",
    provider: "local",
    collectors: [
      { name: "node-info" as const, enabled: true },
      { name: "node-resources" as const, enabled: true },
      { name: "custom-json" as const, enabled: true, files: [] },
      { name: "agent-health" as const, enabled: true }
    ]
  };
  await writeFile(nodeConfigPath, JSON.stringify(nodeConfig));
  const config = testConfig({
    mode: "daemon",
    outputModes,
    nodeId: "example-linux-01",
    hostname: "example-linux-01",
    region: "local",
    nodeConfigPath,
    collectorConfigs: nodeConfig.collectors,
    serverBatchLatestFile: path.join(dir, "server-batch-latest.safe.json"),
    serverBatchOutputFile: path.join(dir, "server-batch.safe.json"),
    agentHealthOutputFile: path.join(dir, "agent-health-latest.safe.json"),
    statePath: path.join(dir, "state.json"),
    spoolDir: path.join(dir, "spool"),
    intervalSeconds: 1,
    ...overrides
  });
  return { config, nodeConfig };
}

async function fetchJson(url: string): Promise<unknown> {
  const response = await fetch(url);
  expect(response.ok).toBe(true);
  return response.json();
}

async function closeServer(server: http.Server): Promise<void> {
  await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
}
