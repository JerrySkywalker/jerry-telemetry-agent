import type { Config } from "../config.js";

export interface TelemetryEnvelope {
  schema_version: "v1";
  event_type: "codex.status";
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
  return {
    schema_version: "v1",
    event_type: "codex.status",
    source: {
      node_id: config.nodeId,
      hostname: config.hostname,
      region: config.region,
      collector: config.collector
    },
    captured_at: capturedAt,
    payload
  };
}

export function stablePayloadHash(payload: unknown): string {
  return JSON.stringify(sortValue(payload));
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
