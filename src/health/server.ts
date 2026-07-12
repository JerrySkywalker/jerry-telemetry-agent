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
      writeJson(res, latest ? localCodexStatus(latest, state.lastSuccessfulUsageAt ?? state.lastSuccessfulSendAt) : { error: "not_found" }, latest ? 200 : 404);
      return;
    }
    if (req.url === "/api/codex/usage/summary") {
      const latest = await readSnapshot(config.usageLatestPath);
      writeJson(res, latest ? localCodexStatus(latest, state.lastSuccessfulUsageAt ?? state.lastSuccessfulSendAt) : { error: "not_found" }, latest ? 200 : 404);
      return;
    }
    if (req.url === "/api/agent/health/latest") {
      const latest = await readJson(config.agentHealthOutputFile);
      writeJson(res, latest ? localAgentHealthStatus(latest) : { error: "not_found" }, latest ? 200 : 404);
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
      last_error_present: Boolean(state.lastError),
      pending_spool_count: await countSpooledEvents(config.spoolDir),
      pending_batch_spool_count: await countSpooledBatches(config.spoolDir),
      last_payload_captured_at: state.lastPayloadCapturedAt,
      last_server_batch_captured_at: state.lastServerBatchCapturedAt
    };
    writeJson(res, body);
  });
  server.listen(config.healthPort, config.healthHost);
  return server;
}

function localCodexStatus(snapshot: CodexUsageSnapshot, lastSuccessAt?: string): Record<string, unknown> {
  const { node_id: _nodeId, ...safe } = summarizeCodexUsage(snapshot, lastSuccessAt);
  return { ...safe, output_allowlist_version: "jerry.agent.health.v1" };
}

function localAgentHealthStatus(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return { ok: false, status_available: false, output_allowlist_version: "jerry.agent.health.v1" };
  const record = value as Record<string, unknown>;
  const status = objectRecord(record.status);
  const outputs = objectRecord(record.outputs);
  const agent = objectRecord(record.agent);
  return {
    ok: status.ok === true,
    degraded: status.degraded === true,
    observed_at: typeof record.observed_at === "string" ? record.observed_at : null,
    agent_version: typeof agent.version === "string" ? agent.version : null,
    pending_spool_count: typeof outputs.pending_spool_count === "number" ? outputs.pending_spool_count : 0,
    last_http_success_at: typeof outputs.last_http_success_at === "string" ? outputs.last_http_success_at : null,
    last_http_error_present: Boolean(outputs.last_http_error_at),
    output_allowlist_version: "jerry.agent.health.v1"
  };
}

function objectRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

export async function waitForHealthServerListening(server: http.Server): Promise<void> {
  if (server.listening) return;
  await new Promise<void>((resolve, reject) => {
    const onListening = () => {
      server.off("error", onError);
      resolve();
    };
    const onError = (error: Error) => {
      server.off("listening", onListening);
      reject(error);
    };
    server.once("listening", onListening);
    server.once("error", onError);
  });
}

export async function closeHealthServer(server: http.Server, graceMs = 5_000): Promise<void> {
  if (!server.listening) return;
  await new Promise<void>((resolve, reject) => {
    let settled = false;
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(forceTimer);
      clearTimeout(deadlineTimer);
      if (error) reject(error);
      else resolve();
    };
    const forceTimer = setTimeout(() => server.closeAllConnections(), graceMs);
    const deadlineTimer = setTimeout(() => {
      server.closeAllConnections();
      finish(new Error("health_server_shutdown_timeout"));
    }, graceMs * 2);
    server.close((error) => finish(error));
  });
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
