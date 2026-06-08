import http from "node:http";
import type { Config } from "../config.js";
import { readState } from "../telemetry/state.js";
import { countSpooledEvents } from "../telemetry/spool.js";

export function startHealthServer(config: Config): http.Server {
  const server = http.createServer(async (req, res) => {
    if (!req.url || !["/healthz", "/status"].includes(req.url)) {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_found" }));
      return;
    }
    const state = await readState(config.statePath);
    const body = {
      ok: req.url === "/healthz" ? !state.lastError : undefined,
      provider: config.provider,
      last_success: state.lastSuccessfulSendAt,
      last_error: state.lastError,
      pending_spool_count: await countSpooledEvents(config.spoolDir),
      last_payload_captured_at: state.lastPayloadCapturedAt,
      node_id: config.nodeId,
      hostname: config.hostname
    };
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
  });
  server.listen(config.healthPort, config.healthHost);
  return server;
}
