import packageJson from "../../package.json" with { type: "json" };
import { collectCustomJsonFiles } from "./custom/jsonFile.js";
import { collectDockerContainers } from "./docker/containers.js";
import { collectLinuxNodeInfo } from "./linux/nodeInfo.js";
import { collectLinuxResources } from "./linux/resources.js";
import { collectHttpProbes } from "./probes/httpProbe.js";
import { collectMessageGatewayReadiness } from "./messageGatewayReadiness.js";
import { collectTcpProbes } from "./probes/tcpProbe.js";
import { collectorEventType, type CollectorName, type DeclarativeNodeConfig, type HttpProbeTarget, type MessageGatewayReadinessTarget, type NodeCollectorConfig, type TcpProbeTarget } from "./registry.js";
import { collectorErrorPayload, type ServerCollectorContext } from "./serverTypes.js";
import { collectSystemdUnits } from "./systemd/units.js";
import { buildTelemetryBatch, buildTelemetryEnvelope, type TelemetryBatch, type TelemetryEnvelope } from "../telemetry/envelope.js";
import { assertNoForbiddenTelemetryMarkers } from "../telemetry/forbiddenMarkers.js";
import { sanitizeErrorForTelemetry } from "../telemetry/sanitize.js";

export interface ServerBatchOptions {
  capturedAt?: string;
  httpEnabled?: boolean;
}

interface CollectorStatus {
  name: string;
  enabled: boolean;
  ok: boolean;
  message: string;
  event_type?: string;
}

export async function buildServerTelemetryBatch(config: DeclarativeNodeConfig, options: ServerBatchOptions = {}): Promise<TelemetryBatch> {
  const capturedAt = options.capturedAt ?? new Date().toISOString();
  const context: ServerCollectorContext = {
    nodeId: config.node_id ?? "unknown",
    hostname: config.hostname ?? config.node_id ?? "unknown",
    region: config.region ?? "unknown",
    role: config.role ?? "general-linux-node",
    provider: config.provider ?? "local",
    capturedAt
  };
  const events: TelemetryEnvelope[] = [];
  const statuses: CollectorStatus[] = [];

  for (const collector of config.collectors ?? []) {
    if (!collector.enabled) continue;
    if (collector.name === "agent-health") continue;
    const result = await collectServerCollector(collector, context);
    events.push(result.event);
    statuses.push(result.status);
  }

  if ((config.collectors ?? []).some((collector) => collector.name === "agent-health" && collector.enabled)) {
    events.push(buildServerEvent("agent-health", context, buildServerAgentHealthPayload(context, statuses, options.httpEnabled === true)));
  }

  const batch = buildTelemetryBatch(events);
  assertNoForbiddenTelemetryMarkers(batch);
  return batch;
}

async function collectServerCollector(
  collector: NodeCollectorConfig,
  context: ServerCollectorContext
): Promise<{ event: TelemetryEnvelope; status: CollectorStatus }> {
  try {
    const payload = await runCollector(collector, context);
    return {
      event: buildServerEvent(collector.name, context, payload),
      status: {
        name: collector.name,
        enabled: true,
        ok: true,
        message: "collector ok",
        event_type: collectorEventType(collector.name)
      }
    };
  } catch (error) {
    const safe = sanitizeErrorForTelemetry(error, "collector_error");
    return {
      event: buildServerEvent(collector.name, context, {
        status: collectorErrorPayload(safe.error_code, safe.message),
        collector: { name: collector.name }
      }),
      status: {
        name: collector.name,
        enabled: true,
        ok: false,
        message: safe.message,
        event_type: collectorEventType(collector.name)
      }
    };
  }
}

async function runCollector(collector: NodeCollectorConfig, context: ServerCollectorContext): Promise<Record<string, unknown>> {
  switch (collector.name) {
    case "node-info":
      return collectLinuxNodeInfo(context);
    case "node-resources":
      return collectLinuxResources();
    case "service-health":
      return {
        services: [
          {
            name: "local-service-fixture",
            kind: "fixture",
            status: "unknown",
            last_check: context.capturedAt,
            message: "no service fixture configured",
            response_time_ms: null,
            port: null
          }
        ]
      };
    case "http-probe":
      return collectHttpProbes((collector.targets ?? []) as HttpProbeTarget[], context.capturedAt);
    case "tcp-probe":
      return collectTcpProbes((collector.targets ?? []) as TcpProbeTarget[], context.capturedAt);
    case "message-gateway-readiness":
      return { ...await collectMessageGatewayReadiness((collector.target ?? {}) as MessageGatewayReadinessTarget, context.capturedAt) };
    case "docker-containers":
      return collectDockerContainers(collector.allowlist);
    case "systemd-units":
      return collectSystemdUnits(collector.units ?? []);
    case "custom-json":
      return collectCustomJsonFiles(collector.files, context.capturedAt);
    default:
      throw new Error(`Unsupported server collector: ${collector.name}`);
  }
}

function buildServerEvent(collector: CollectorName, context: ServerCollectorContext, payload: Record<string, unknown>): TelemetryEnvelope {
  const source = collector === "message-gateway-readiness"
    ? { node_id: context.nodeId, collector }
    : {
        node_id: context.nodeId,
        hostname: context.hostname,
        region: context.region,
        collector
      };
  return buildTelemetryEnvelope(
    source,
    collectorEventType(collector),
    payload,
    context.capturedAt
  );
}

function buildServerAgentHealthPayload(context: ServerCollectorContext, statuses: CollectorStatus[], httpEnabled: boolean): Record<string, unknown> {
  const degraded = statuses.some((status) => !status.ok);
  return {
    type: "telemetry.agent.health",
    schema_version: 1,
    observed_at: context.capturedAt,
    node: {
      id: context.nodeId,
      hostname: context.hostname,
      region: context.region,
      platform: process.platform
    },
    agent: {
      name: "jerry-telemetry-agent",
      version: packageJson.version,
      mode: "once",
      uptime_seconds: Math.max(0, Math.floor(process.uptime())),
      started_at: context.capturedAt
    },
    status: {
      ok: !degraded,
      degraded,
      message: degraded ? "server batch degraded" : "server batch healthy"
    },
    collectors: statuses.map((status) => ({
      name: status.name,
      enabled: status.enabled,
      last_success_at: status.ok ? context.capturedAt : null,
      last_error_at: status.ok ? null : context.capturedAt,
      last_error_code: status.ok ? null : "collector_error",
      latest_payload_status_ok: status.ok
    })),
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
    raw_omitted_keys: ["raw_env", "raw_logs", "raw_auth", "raw_command_output"]
  };
}
