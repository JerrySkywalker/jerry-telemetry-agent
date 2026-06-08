import http from "node:http";
import { readFile } from "node:fs/promises";
import type { Config } from "../config.js";
import { readState } from "../telemetry/state.js";
import { countSpooledEvents } from "../telemetry/spool.js";
import { summarizeCodexUsage } from "../collectors/codex/normalizer.js";
import type { CodexUsageSnapshot } from "../types/codex-usage.js";

export function startHealthServer(config: Config): http.Server {
  const server = http.createServer(async (req, res) => {
    if (!req.url || !["/healthz", "/status", "/api/codex/usage/latest", "/api/codex/usage/summary"].includes(req.url)) {
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
    const body = {
      ok: req.url === "/healthz" ? !state.lastError : undefined,
      collector: config.collectorMode,
      last_success: state.lastSuccessfulSendAt,
      last_usage_success: state.lastSuccessfulUsageAt,
      last_error: state.lastError,
      pending_spool_count: await countSpooledEvents(config.spoolDir),
      last_payload_captured_at: state.lastPayloadCapturedAt,
      node_id: config.nodeId,
      hostname: config.hostname
    };
    writeJson(res, body);
  });
  server.listen(config.healthPort, config.healthHost);
  return server;
}

async function readSnapshot(file: string): Promise<CodexUsageSnapshot | undefined> {
  try {
    return JSON.parse(await readFile(file, "utf8")) as CodexUsageSnapshot;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

function writeJson(res: http.ServerResponse, body: unknown, status = 200): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}
