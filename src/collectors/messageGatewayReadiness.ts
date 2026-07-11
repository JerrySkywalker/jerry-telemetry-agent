import type { MessageGatewayReadinessTarget } from "./registry.js";

export const MESSAGE_GATEWAY_READINESS_SCHEMA_VERSION = "jerry.message-gateway.readiness.v1";
export const MESSAGE_GATEWAY_READINESS_TTL_SECONDS = 300;

export type MessageGatewayReadinessStatus = "healthy" | "degraded" | "unavailable" | "stale" | "not_configured";
type Reachability = "reachable" | "unreachable" | "unknown";
type DependencyStatus = "ready" | "not_configured" | "unavailable" | "unknown";
type FailureClass =
  | "none"
  | "configuration_incomplete"
  | "dependency_unavailable"
  | "operation_stale"
  | "endpoint_unreachable"
  | "invalid_contract"
  | "internal_error";

export interface MessageGatewayReadinessEvidence {
  schema_version: typeof MESSAGE_GATEWAY_READINESS_SCHEMA_VERSION;
  service_id: "jerry-message-gateway";
  observed_at: string;
  status: MessageGatewayReadinessStatus;
  process_reachability: Reachability;
  dependencies: {
    configuration: DependencyStatus;
    message_store: DependencyStatus;
    delivery_path: DependencyStatus;
  };
  last_success_at: string | null;
  failure_class: FailureClass;
  source: "telemetry_agent_local_probe";
  freshness_ttl_seconds: typeof MESSAGE_GATEWAY_READINESS_TTL_SECONDS;
  version: string | null;
}

export async function collectMessageGatewayReadiness(
  target: MessageGatewayReadinessTarget,
  capturedAt: string,
  fetchImpl: typeof fetch = fetch
): Promise<MessageGatewayReadinessEvidence> {
  try {
    const response = await fetchImpl(target.url, {
      method: "GET",
      redirect: "manual",
      signal: AbortSignal.timeout(target.timeout_ms ?? 2000)
    });
    if (!response.ok) {
      return unavailable(capturedAt, "endpoint_unreachable");
    }
    return normalize(await response.json(), capturedAt) ?? unavailable(capturedAt, "invalid_contract");
  } catch {
    return unavailable(capturedAt, "endpoint_unreachable");
  }
}

function normalize(value: unknown, fallbackObservedAt: string): MessageGatewayReadinessEvidence | undefined {
  if (!isRecord(value) || value.schema_version !== MESSAGE_GATEWAY_READINESS_SCHEMA_VERSION || value.service_id !== "jerry-message-gateway") {
    return undefined;
  }
  const status = statusValue(value.status);
  const reachability = reachabilityValue(value.process_reachability);
  const dependencies = dependenciesValue(value.dependencies);
  const failureClass = failureClassValue(value.failure_class);
  const observedAt = isoTimestamp(value.observed_at) ? value.observed_at : undefined;
  const lastSuccessAt = value.last_success_at === null ? null : isoTimestamp(value.last_success_at) ? value.last_success_at : undefined;
  const version = value.version === null ? null : safeVersion(value.version) ? value.version : undefined;
  if (!status || !reachability || !dependencies || !failureClass || !observedAt || lastSuccessAt === undefined || version === undefined || value.freshness_ttl_seconds !== MESSAGE_GATEWAY_READINESS_TTL_SECONDS) {
    return undefined;
  }
  return {
    schema_version: MESSAGE_GATEWAY_READINESS_SCHEMA_VERSION,
    service_id: "jerry-message-gateway",
    observed_at: observedAt,
    status,
    process_reachability: reachability,
    dependencies,
    last_success_at: lastSuccessAt,
    failure_class: failureClass,
    source: "telemetry_agent_local_probe",
    freshness_ttl_seconds: MESSAGE_GATEWAY_READINESS_TTL_SECONDS,
    version
  };
}

function unavailable(observedAt: string, failureClass: "endpoint_unreachable" | "invalid_contract"): MessageGatewayReadinessEvidence {
  return {
    schema_version: MESSAGE_GATEWAY_READINESS_SCHEMA_VERSION,
    service_id: "jerry-message-gateway",
    observed_at: observedAt,
    status: "unavailable",
    process_reachability: failureClass === "endpoint_unreachable" ? "unreachable" : "unknown",
    dependencies: { configuration: "unknown", message_store: "unknown", delivery_path: "unknown" },
    last_success_at: null,
    failure_class: failureClass,
    source: "telemetry_agent_local_probe",
    freshness_ttl_seconds: MESSAGE_GATEWAY_READINESS_TTL_SECONDS,
    version: null
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function isoTimestamp(value: unknown): value is string { return typeof value === "string" && Number.isFinite(Date.parse(value)); }
function safeVersion(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/.test(value); }
function statusValue(value: unknown): MessageGatewayReadinessStatus | undefined {
  return typeof value === "string" && ["healthy", "degraded", "unavailable", "stale", "not_configured"].includes(value) ? value as MessageGatewayReadinessStatus : undefined;
}
function reachabilityValue(value: unknown): Reachability | undefined {
  return typeof value === "string" && ["reachable", "unreachable", "unknown"].includes(value) ? value as Reachability : undefined;
}
function dependencyValue(value: unknown): DependencyStatus | undefined {
  return typeof value === "string" && ["ready", "not_configured", "unavailable", "unknown"].includes(value) ? value as DependencyStatus : undefined;
}
function dependenciesValue(value: unknown): MessageGatewayReadinessEvidence["dependencies"] | undefined {
  if (!isRecord(value)) return undefined;
  const configuration = dependencyValue(value.configuration);
  const messageStore = dependencyValue(value.message_store);
  const deliveryPath = dependencyValue(value.delivery_path);
  return configuration && messageStore && deliveryPath ? { configuration, message_store: messageStore, delivery_path: deliveryPath } : undefined;
}
function failureClassValue(value: unknown): FailureClass | undefined {
  return typeof value === "string" && ["none", "configuration_incomplete", "dependency_unavailable", "operation_stale", "endpoint_unreachable", "invalid_contract", "internal_error"].includes(value) ? value as FailureClass : undefined;
}
