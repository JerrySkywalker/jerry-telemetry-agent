import http from "node:http";
import { readFile } from "node:fs/promises";
import type { Config } from "../config.js";
import { readState } from "../telemetry/state.js";
import { countAllSpooledPayloads, countSpooledBatches, countSpooledEvents } from "../telemetry/spool.js";
import { summarizeCodexUsage } from "../collectors/codex/normalizer.js";
import type { CodexUsageSnapshot } from "../types/codex-usage.js";
import { buildServerStatusSummary, summarizeServerBatchForStatus } from "../serverStatus.js";
import { sanitizeSnapshotPayload } from "../telemetry/sanitize.js";

export function startHealthServer(config: Config): http.Server {
  const server = http.createServer(async (req, res) => {
    if (
      !req.url ||
      ![
        "/healthz",
        "/status",
        "/api/codex/usage/latest",
        "/api/codex/usage/summary",
        "/api/agent/health/latest",
        "/api/server/status",
        "/api/server/batch/latest"
      ].includes(req.url)
    ) {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_found" }));
      return;
    }
    const state = await readState(config.statePath);
    if (req.url === "/api/codex/usage/latest") {
      const latest = await readSnapshot(config.usageLatestPath);
      writeJson(res, latest ?? { error: "not_found" }, latest ? 200 : 404);
      return;
    }
    if (req.url === "/api/codex/usage/summary") {
      const latest = await readSnapshot(config.usageLatestPath);
      writeJson(res, latest ? summarizeCodexUsage(latest, state.lastSuccessfulUsageAt ?? state.lastSuccessfulSendAt) : { error: "not_found" }, latest ? 200 : 404);
      return;
    }
    if (req.url === "/api/agent/health/latest") {
      const latest = await readJson(config.agentHealthOutputFile);
      writeJson(res, latest ?? { error: "not_found" }, latest ? 200 : 404);
      return;
    }
    if (req.url === "/api/server/status") {
      const [pendingSpoolCount, pendingBatchSpoolCount] = await Promise.all([countAllSpooledPayloads(config.spoolDir), countSpooledBatches(config.spoolDir)]);
      writeJson(res, buildServerStatusSummary(config, state, { pendingSpoolCount, pendingBatchSpoolCount }));
      return;
    }
    if (req.url === "/api/server/batch/latest") {
      const latest = await readJson(config.serverBatchLatestFile);
      const summary = latest ? summarizeServerBatchForStatus(latest) : undefined;
      writeJson(res, summary ?? { error: "not_found" }, summary ? 200 : 404);
      return;
    }
    const body = {
      ok: req.url === "/healthz" ? !state.lastError : undefined,
      collector: config.collectorMode,
      last_success: state.lastSuccessfulSendAt,
      last_usage_success: state.lastSuccessfulUsageAt,
      last_error: state.lastError,
      pending_spool_count: await countSpooledEvents(config.spoolDir),
      pending_batch_spool_count: await countSpooledBatches(config.spoolDir),
      last_payload_captured_at: state.lastPayloadCapturedAt,
      last_server_batch_captured_at: state.lastServerBatchCapturedAt,
      node_id: config.nodeId,
      hostname: config.hostname
    };
    writeJson(res, body);
  });
  server.listen(config.healthPort, config.healthHost);
  return server;
}

async function readSnapshot(file: string): Promise<CodexUsageSnapshot | undefined> {
  return readJson(file) as Promise<CodexUsageSnapshot | undefined>;
}

async function readJson(file: string): Promise<unknown | undefined> {
  try {
    return sanitizeSnapshotPayload(JSON.parse(await readFile(file, "utf8")) as unknown);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

function writeJson(res: http.ServerResponse, body: unknown, status = 200): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}
