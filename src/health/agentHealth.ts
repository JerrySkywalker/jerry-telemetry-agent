import type { Config } from "../config.js";
import type { AgentState } from "../telemetry/state.js";
import { countSpooledEvents } from "../telemetry/spool.js";
import type { AgentHealthSnapshot } from "../types/agent-health.js";
import type { CodexUsageSnapshot } from "../types/codex-usage.js";
import packageJson from "../../package.json" with { type: "json" };

const startedAt = new Date().toISOString();
const omittedKeys = ["secrets", "tokens", "env", "auth_json", "raw_response", "authorization_header", "account_identity"];

export interface AgentHealthContext {
  state: AgentState;
  latestUsage?: CodexUsageSnapshot;
  collectorErrorCode?: string | null;
  collectorErrorAt?: string | null;
  lastHttpErrorAt?: string | null;
}

export async function buildAgentHealthSnapshot(config: Config, context: AgentHealthContext): Promise<AgentHealthSnapshot> {
  const observedAt = new Date().toISOString();
  const pendingSpoolCount = await countSpooledEvents(config.spoolDir);
  const latestUsage = context.latestUsage;
  const collectorOk = latestUsage?.status.ok ?? false;
  const collectorErrorCode = context.collectorErrorCode ?? latestUsage?.status.error_code ?? null;
  const collectorLastSuccessAt = latestUsage?.status.ok ? latestUsage.observed_at : context.state.lastSuccessfulUsageAt ?? null;
  const collectorLastErrorAt = collectorErrorCode ? context.collectorErrorAt ?? latestUsage?.observed_at ?? observedAt : null;
  const httpEnabled = config.outputModes.includes("http");
  const degraded = !collectorOk || pendingSpoolCount > 0 || Boolean(collectorErrorCode);

  return {
    type: config.agentHealthEventType,
    schema_version: 1,
    observed_at: observedAt,
    node: {
      id: config.nodeId || "unknown",
      hostname: config.hostname || "unknown",
      region: config.region || "unknown",
      platform: config.platform || "unknown"
    },
    agent: {
      name: "jerry-telemetry-agent",
      version: packageJson.version,
      mode: config.mode,
      uptime_seconds: Math.max(0, Math.floor(process.uptime())),
      started_at: startedAt
    },
    status: {
      ok: !degraded,
      degraded,
      message: degraded ? "agent degraded" : "agent healthy"
    },
    collectors: [
      {
        name: config.collectorMode,
        enabled: true,
        last_success_at: collectorLastSuccessAt,
        last_error_at: collectorLastErrorAt,
        last_error_code: collectorErrorCode,
        latest_payload_status_ok: latestUsage?.status.ok ?? null,
        latest_limits_count: latestUsage?.limits.length ?? null
      }
    ],
    outputs: {
      file_enabled: config.outputModes.includes("file"),
      http_enabled: httpEnabled,
      last_http_success_at: context.state.lastSuccessfulSendAt ?? null,
      last_http_error_at: context.lastHttpErrorAt ?? context.state.lastHttpErrorAt ?? null,
      pending_spool_count: pendingSpoolCount
    },
    config: {
      poll_interval_seconds: config.intervalSeconds,
      provider: config.provider,
      tmux_fallback_enabled: config.collectorMode === "codex-cli-status-fallback",
      health_server_enabled: config.healthServerEnabled
    },
    security: {
      auth_dir_mounted_readonly: "unknown",
      node_secret_present: Boolean(config.nodeSecret)
    },
    raw_omitted_keys: omittedKeys
  };
}
