import type { Config } from "../config.js";
import { sanitizeSnapshotPayload } from "./sanitize.js";

export interface TelemetryEnvelope {
  schema_version: "v1";
  event_type: "codex.status" | "codex.usage.snapshot" | "telemetry.agent.health";
  source: {
    node_id: string;
    hostname: string;
    region: string;
    collector: string;
  };
  captured_at: string;
  payload: Record<string, unknown>;
}

export function buildEnvelope(config: Config, payload: Record<string, unknown>, capturedAt = new Date().toISOString()): TelemetryEnvelope {
  const safePayload = sanitizeSnapshotPayload(payload);
  const eventType =
    safePayload.type === "codex.usage.snapshot"
      ? "codex.usage.snapshot"
      : safePayload.type === config.agentHealthEventType
        ? config.agentHealthEventType
        : "codex.status";
  return {
    schema_version: "v1",
    event_type: eventType,
    source: {
      node_id: config.nodeId,
      hostname: config.hostname,
      region: config.region,
      collector: config.collector
    },
    captured_at: capturedAt,
    payload: safePayload
  };
}

export function stablePayloadHash(payload: unknown): string {
  return JSON.stringify(sortValue(sanitizeSnapshotPayload(payload)));
}

function sortValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, item]) => [key, sortValue(item)])
    );
  }
  return value;
}
