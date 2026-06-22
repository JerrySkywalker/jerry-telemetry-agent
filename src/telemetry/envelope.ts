import type { Config } from "../config.js";
import { collectorEventType, type CollectorEventType } from "../collectors/registry.js";
import { sanitizeSnapshotPayload } from "./sanitize.js";

export interface TelemetryEnvelope {
  schema_version: "v1";
  event_type: CollectorEventType;
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
  const eventType = resolveEventType(config, safePayload);
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

function resolveEventType(config: Config, payload: Record<string, unknown>): CollectorEventType {
  if (payload.type === "codex.usage.snapshot" || payload.type === config.agentHealthEventType) {
    return payload.type;
  }
  if (typeof payload.type === "string") {
    throw new Error(`Unsupported telemetry event type: ${payload.type}`);
  }
  return collectorEventType(config.collector);
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
