import type { Config } from "../config.js";
import { collectorEventType, isCollectorEventType, type CollectorEventType } from "../collectors/registry.js";
import { sanitizeSnapshotPayload } from "./sanitize.js";

export interface TelemetrySource {
  node_id: string;
  hostname: string;
  region: string;
  collector: string;
}

export interface TelemetryEnvelope {
  schema_version: "v1";
  event_type: CollectorEventType;
  source: TelemetrySource;
  captured_at: string;
  payload: Record<string, unknown>;
}

export interface TelemetryBatch {
  schema_version: "v1";
  events: TelemetryEnvelope[];
}

export function buildEnvelope(config: Config, payload: Record<string, unknown>, capturedAt = new Date().toISOString()): TelemetryEnvelope {
  return buildTelemetryEnvelope(
    {
      node_id: config.nodeId,
      hostname: config.hostname,
      region: config.region,
      collector: config.collector
    },
    resolveEventType(config, sanitizeSnapshotPayload(payload)),
    payload,
    capturedAt
  );
}

export function buildTelemetryEnvelope(
  source: TelemetrySource,
  eventType: CollectorEventType,
  payload: Record<string, unknown>,
  capturedAt = new Date().toISOString()
): TelemetryEnvelope {
  return {
    schema_version: "v1",
    event_type: eventType,
    source,
    captured_at: capturedAt,
    payload: sanitizeSnapshotPayload(payload)
  };
}

export function buildTelemetryBatch(events: TelemetryEnvelope[]): TelemetryBatch {
  return {
    schema_version: "v1",
    events: sanitizeSnapshotPayload(events)
  };
}

function resolveEventType(config: Config, payload: Record<string, unknown>): CollectorEventType {
  if (typeof payload.type === "string" && isCollectorEventType(payload.type)) {
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
