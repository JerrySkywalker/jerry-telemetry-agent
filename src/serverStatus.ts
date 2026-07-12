import type { Config } from "./config.js";
import type { AgentState } from "./telemetry/state.js";
import { findForbiddenTelemetryMarkers } from "./telemetry/forbiddenMarkers.js";

export interface ServerBatchStatusSummary {
  schema_version: "v1";
  events_count: number;
  event_types: string[];
  captured_at?: string;
  forbidden_markers_found: boolean;
  payloads_included: false;
}

export function buildServerStatusSummary(config: Config, state: AgentState, counts: { pendingSpoolCount: number; pendingBatchSpoolCount: number }) {
  return {
    daemon_mode: state.daemonMode ?? "server",
    collector_names: state.collectorNames ?? enabledCollectorNames(config),
    last_batch_captured_at: state.lastServerBatchCapturedAt ?? null,
    last_batch_event_types: state.lastServerBatchEventTypes ?? [],
    last_batch_events_count: state.lastServerBatchEventsCount ?? 0,
    last_batch_successful_send_at: state.lastServerBatchSuccessfulSendAt ?? null,
    last_batch_http_error_at: state.lastServerBatchHttpErrorAt ?? null,
    last_batch_error_present: Boolean(state.lastServerBatchError),
    daemon_started_at: state.daemonStartedAt ?? null,
    pending_spool_count: counts.pendingSpoolCount,
    pending_batch_spool_count: counts.pendingBatchSpoolCount
  };
}

export function summarizeServerBatchForStatus(value: unknown): ServerBatchStatusSummary | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const batch = value as Record<string, unknown>;
  if (batch.schema_version !== "v1" || !Array.isArray(batch.events)) return undefined;
  const events = batch.events.filter((event): event is Record<string, unknown> => Boolean(event) && typeof event === "object" && !Array.isArray(event));
  return {
    schema_version: "v1",
    events_count: events.length,
    event_types: [...new Set(events.map((event) => String(event.event_type ?? "unknown")))],
    captured_at: firstString(events, "captured_at"),
    forbidden_markers_found: findForbiddenTelemetryMarkers(value).length > 0,
    payloads_included: false
  };
}

function enabledCollectorNames(config: Config): string[] {
  return config.collectorConfigs.filter((collector) => collector.enabled).map((collector) => collector.name);
}

function firstString(events: Array<Record<string, unknown>>, key: string): string | undefined {
  const value = events.find((event) => typeof event[key] === "string")?.[key];
  return typeof value === "string" ? value : undefined;
}
