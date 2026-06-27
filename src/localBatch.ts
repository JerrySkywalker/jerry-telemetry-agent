import packageJson from "../package.json" with { type: "json" };
import { collectorEventType, type LocalCollectorName } from "./collectors/registry.js";
import {
  collectCustomJson,
  collectNodeInfo,
  collectNodeResources,
  collectServiceHealth,
  type LocalCollectionMode,
  type LocalCollectorContext
} from "./collectors/local.js";
import { buildTelemetryBatch, buildTelemetryEnvelope, type TelemetryBatch, type TelemetryEnvelope, type TelemetrySource } from "./telemetry/envelope.js";
import { assertNoForbiddenTelemetryMarkers } from "./telemetry/forbiddenMarkers.js";

export interface LocalBatchOptions {
  mode: LocalCollectionMode;
  nodeId: string;
  hostname?: string;
  region: string;
  role: string;
  provider: string;
  capturedAt?: string;
  customJsonFile?: string;
  serviceHealthFile?: string;
  includeAgentHealth?: boolean;
  httpEnabled?: boolean;
}

export async function buildLocalTelemetryBatch(options: LocalBatchOptions): Promise<TelemetryBatch> {
  const capturedAt = options.capturedAt ?? new Date().toISOString();
  const hostname = options.hostname || options.nodeId;
  const context: LocalCollectorContext = {
    mode: options.mode,
    nodeId: options.nodeId,
    hostname,
    region: options.region,
    role: options.role,
    provider: options.provider,
    capturedAt,
    customJsonFile: options.customJsonFile,
    serviceHealthFile: options.serviceHealthFile
  };

  const events: TelemetryEnvelope[] = [
    eventFor("node-info", context, collectNodeInfo(context)),
    eventFor("node-resources", context, await collectNodeResources(context)),
    eventFor("service-health", context, await collectServiceHealth(context)),
    eventFor("custom-json", context, await collectCustomJson(context))
  ];

  if (options.includeAgentHealth !== false) {
    events.push(eventFor("agent-health", context, buildLocalAgentHealthPayload(context, options.httpEnabled === true)));
  }

  const batch = buildTelemetryBatch(events);
  assertNoForbiddenTelemetryMarkers(batch);
  return batch;
}

function eventFor(collector: LocalCollectorName | "agent-health", context: LocalCollectorContext, payload: Record<string, unknown>): TelemetryEnvelope {
  return buildTelemetryEnvelope(sourceFor(context, collector), collectorEventType(collector), payload, context.capturedAt);
}

function sourceFor(context: LocalCollectorContext, collector: string): TelemetrySource {
  return {
    node_id: context.nodeId,
    hostname: context.hostname,
    region: context.region,
    collector
  };
}

function buildLocalAgentHealthPayload(context: LocalCollectorContext, httpEnabled: boolean): Record<string, unknown> {
  return {
    type: "telemetry.agent.health",
    schema_version: 1,
    observed_at: context.capturedAt,
    node: {
      id: context.nodeId,
      hostname: context.hostname,
      region: context.region,
      platform: context.mode === "Fixture" ? "fixture" : process.platform
    },
    agent: {
      name: "jerry-telemetry-agent",
      version: packageJson.version,
      mode: "once",
      uptime_seconds: Math.max(0, Math.floor(process.uptime())),
      started_at: context.capturedAt
    },
    status: {
      ok: true,
      degraded: false,
      message: "agent one-shot batch healthy"
    },
    collectors: [
      { name: "node-info", enabled: true, last_success_at: context.capturedAt },
      { name: "node-resources", enabled: true, last_success_at: context.capturedAt },
      { name: "service-health", enabled: true, last_success_at: context.capturedAt },
      { name: "custom-json", enabled: true, last_success_at: context.capturedAt }
    ],
    outputs: {
      file_enabled: true,
      http_enabled: httpEnabled,
      last_http_success_at: null,
      last_http_error_at: null,
      pending_spool_count: 0
    },
    config: {
      poll_interval_seconds: 0,
      provider: context.provider,
      tmux_fallback_enabled: false,
      health_server_enabled: false
    },
    security: {
      auth_dir_mounted_readonly: "unknown",
      node_secret_present: httpEnabled
    },
    raw_omitted_keys: ["sensitive_inputs_omitted"]
  };
}
