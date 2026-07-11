export type UsageCollectorName = "codex-backend-usage" | "codex-cli-status-fallback";
export type LocalCollectorName = "node-info" | "node-resources" | "service-health" | "custom-json";
export type ProbeCollectorName = "http-probe" | "tcp-probe" | "message-gateway-readiness";
export type ReadOnlyCollectorName = "docker-containers" | "systemd-units";
export type ServerCollectorName = LocalCollectorName | ProbeCollectorName | ReadOnlyCollectorName;
export type CollectorName = UsageCollectorName | "agent-health" | ServerCollectorName;
export type CollectorEventType =
  | "codex.usage.snapshot"
  | "telemetry.agent.health"
  | "node.snapshot"
  | "node.resources.snapshot"
  | "service.health.snapshot"
  | "message.gateway.readiness"
  | "docker.containers.snapshot"
  | "systemd.units.snapshot"
  | "custom.snapshot";

export interface CollectorDefinition<N extends CollectorName = CollectorName> {
  name: N;
  eventType: CollectorEventType;
  payloadKind:
    | "codex-usage"
    | "agent-health"
    | "node-info"
    | "node-resources"
    | "service-health"
    | "http-probe"
  | "tcp-probe"
  | "message-gateway-readiness"
    | "docker-containers"
    | "systemd-units"
    | "custom-json";
  implemented: boolean;
}

export interface BaseCollectorConfig<N extends CollectorName = CollectorName> {
  name: N;
  enabled: boolean;
  interval_seconds?: number;
}

export interface HttpProbeTarget {
  name: string;
  url: string;
  timeout_ms?: number;
  expected_status?: number;
  method?: "GET" | "HEAD";
}

export interface TcpProbeTarget {
  name: string;
  host: string;
  port: number;
  timeout_ms?: number;
}

export interface MessageGatewayReadinessTarget {
  url: string;
  timeout_ms?: number;
}

export interface CustomJsonFileConfig {
  name: string;
  path: string;
}

export interface NodeCollectorConfig<N extends CollectorName = CollectorName> extends BaseCollectorConfig<N> {
  targets?: Array<HttpProbeTarget | TcpProbeTarget>;
  target?: MessageGatewayReadinessTarget;
  allowlist?: string[];
  units?: string[];
  files?: CustomJsonFileConfig[];
}

export interface DeclarativeNodeConfig {
  node_id?: string;
  hostname?: string;
  region?: string;
  role?: string;
  provider?: string;
  collectors?: NodeCollectorConfig[];
}

export const collectorRegistry = {
  "codex-backend-usage": {
    name: "codex-backend-usage",
    eventType: "codex.usage.snapshot",
    payloadKind: "codex-usage",
    implemented: true
  },
  "codex-cli-status-fallback": {
    name: "codex-cli-status-fallback",
    eventType: "codex.usage.snapshot",
    payloadKind: "codex-usage",
    implemented: true
  },
  "agent-health": {
    name: "agent-health",
    eventType: "telemetry.agent.health",
    payloadKind: "agent-health",
    implemented: true
  },
  "node-info": {
    name: "node-info",
    eventType: "node.snapshot",
    payloadKind: "node-info",
    implemented: true
  },
  "node-resources": {
    name: "node-resources",
    eventType: "node.resources.snapshot",
    payloadKind: "node-resources",
    implemented: true
  },
  "service-health": {
    name: "service-health",
    eventType: "service.health.snapshot",
    payloadKind: "service-health",
    implemented: true
  },
  "http-probe": {
    name: "http-probe",
    eventType: "service.health.snapshot",
    payloadKind: "http-probe",
    implemented: true
  },
  "tcp-probe": {
    name: "tcp-probe",
    eventType: "service.health.snapshot",
    payloadKind: "tcp-probe",
    implemented: true
  },
  "message-gateway-readiness": {
    name: "message-gateway-readiness",
    eventType: "message.gateway.readiness",
    payloadKind: "message-gateway-readiness",
    implemented: true
  },
  "docker-containers": {
    name: "docker-containers",
    eventType: "docker.containers.snapshot",
    payloadKind: "docker-containers",
    implemented: true
  },
  "systemd-units": {
    name: "systemd-units",
    eventType: "systemd.units.snapshot",
    payloadKind: "systemd-units",
    implemented: true
  },
  "custom-json": {
    name: "custom-json",
    eventType: "custom.snapshot",
    payloadKind: "custom-json",
    implemented: true
  }
} satisfies Record<CollectorName, CollectorDefinition>;

const collectorNames = new Set<CollectorName>(Object.keys(collectorRegistry) as CollectorName[]);
const usageCollectorNames = new Set<UsageCollectorName>(["codex-backend-usage", "codex-cli-status-fallback"]);
const collectorEventTypes = new Set<CollectorEventType>(Object.values(collectorRegistry).map((item) => item.eventType));

export function assertCollectorName(value: string | undefined): CollectorName {
  if (value && collectorNames.has(value as CollectorName)) return value as CollectorName;
  throw new Error(`Invalid collector name: ${value ?? ""}`);
}

export function assertUsageCollectorName(value: string | undefined): UsageCollectorName {
  const name = assertCollectorName(value);
  if (!isUsageCollectorName(name)) throw new Error(`${name} is not a usage collector`);
  return name;
}

export function isUsageCollectorName(name: CollectorName): name is UsageCollectorName {
  return usageCollectorNames.has(name as UsageCollectorName);
}

export function collectorEventType(name: CollectorName): CollectorEventType {
  return collectorRegistry[name].eventType;
}

export function isCollectorEventType(value: string): value is CollectorEventType {
  return collectorEventTypes.has(value as CollectorEventType);
}

export function parseDeclarativeNodeConfig(value: unknown): DeclarativeNodeConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Node config must be a JSON object");
  }
  const input = value as Record<string, unknown>;
  return {
    node_id: optionalString(input.node_id, "node_id"),
    hostname: optionalString(input.hostname, "hostname"),
    region: optionalString(input.region, "region"),
    role: optionalString(input.role, "role"),
    provider: optionalString(input.provider, "provider"),
    collectors: input.collectors === undefined ? undefined : parseCollectorConfigs(input.collectors)
  };
}

export function parseCollectorConfigs(value: unknown): NodeCollectorConfig[] {
  if (!Array.isArray(value)) throw new Error("Node config collectors must be an array");
  return value.map((item) => parseCollectorConfig(item));
}

export function activeUsageCollectorFromConfig(collectors: NodeCollectorConfig[] | undefined): UsageCollectorName | undefined {
  const collector = collectors?.find((item): item is BaseCollectorConfig<UsageCollectorName> => item.enabled && isUsageCollectorName(item.name));
  return collector?.name;
}

export function defaultCollectorConfigs(usageCollector: UsageCollectorName, intervalSeconds: number, agentHealthEnabled: boolean): NodeCollectorConfig[] {
  const configs: NodeCollectorConfig[] = [{ name: usageCollector, enabled: true, interval_seconds: intervalSeconds }];
  if (agentHealthEnabled) configs.push({ name: "agent-health", enabled: true, interval_seconds: intervalSeconds });
  return configs;
}

function parseCollectorConfig(value: unknown): NodeCollectorConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Collector config must be a JSON object");
  }
  const input = value as Record<string, unknown>;
  const name = assertCollectorName(requiredString(input.name, "collector.name"));
  const enabled = input.enabled === undefined ? true : requiredBoolean(input.enabled, `${name}.enabled`);
  const interval = input.interval_seconds === undefined ? undefined : requiredPositiveInteger(input.interval_seconds, `${name}.interval_seconds`);
  const base = interval === undefined ? { name, enabled } : { name, enabled, interval_seconds: interval };

  if (name === "http-probe") {
    return { ...base, name, targets: parseHttpProbeTargets(input.targets, enabled) };
  }
  if (name === "tcp-probe") {
    return { ...base, name, targets: parseTcpProbeTargets(input.targets, enabled) };
  }
  if (name === "message-gateway-readiness") {
    return { ...base, name, target: parseMessageGatewayReadinessTarget(input.target, enabled) };
  }
  if (name === "docker-containers") {
    return { ...base, name, allowlist: input.allowlist === undefined ? undefined : parseStringArray(input.allowlist, `${name}.allowlist`) };
  }
  if (name === "systemd-units") {
    const units = parseStringArray(input.units, `${name}.units`);
    if (enabled && units.length === 0) throw new Error("systemd-units.units must include at least one unit when enabled");
    return { ...base, name, units };
  }
  if (name === "custom-json") {
    return { ...base, name, files: input.files === undefined ? undefined : parseCustomJsonFiles(input.files) };
  }
  return base;
}

function optionalString(value: unknown, field: string): string | undefined {
  if (value === undefined) return undefined;
  return requiredString(value, field);
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string") throw new Error(`${field} must be a string`);
  return value;
}

function requiredBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${field} must be a boolean`);
  return value;
}

function requiredPositiveInteger(value: unknown, field: string): number {
  if (!Number.isInteger(value) || (value as number) <= 0) throw new Error(`${field} must be a positive integer`);
  return value as number;
}

function parseHttpProbeTargets(value: unknown, enabled: boolean): HttpProbeTarget[] {
  if (value === undefined) {
    if (enabled) throw new Error("http-probe.targets must be an array when enabled");
    return [];
  }
  if (!Array.isArray(value)) throw new Error("http-probe.targets must be an array");
  return value.map((item, index) => parseHttpProbeTarget(item, `http-probe.targets[${index}]`));
}

function parseHttpProbeTarget(value: unknown, field: string): HttpProbeTarget {
  const input = requiredObject(value, field);
  const method = input.method === undefined ? "GET" : requiredHttpMethod(input.method, `${field}.method`);
  const timeout = input.timeout_ms === undefined ? undefined : requiredPositiveInteger(input.timeout_ms, `${field}.timeout_ms`);
  const expected = input.expected_status === undefined ? undefined : requiredHttpStatus(input.expected_status, `${field}.expected_status`);
  return {
    name: requiredString(input.name, `${field}.name`),
    url: requiredHttpUrl(input.url, `${field}.url`),
    method,
    timeout_ms: timeout,
    expected_status: expected
  };
}

function parseTcpProbeTargets(value: unknown, enabled: boolean): TcpProbeTarget[] {
  if (value === undefined) {
    if (enabled) throw new Error("tcp-probe.targets must be an array when enabled");
    return [];
  }
  if (!Array.isArray(value)) throw new Error("tcp-probe.targets must be an array");
  return value.map((item, index) => parseTcpProbeTarget(item, `tcp-probe.targets[${index}]`));
}

function parseTcpProbeTarget(value: unknown, field: string): TcpProbeTarget {
  const input = requiredObject(value, field);
  return {
    name: requiredString(input.name, `${field}.name`),
    host: requiredString(input.host, `${field}.host`),
    port: requiredPort(input.port, `${field}.port`),
    timeout_ms: input.timeout_ms === undefined ? undefined : requiredPositiveInteger(input.timeout_ms, `${field}.timeout_ms`)
  };
}

function parseMessageGatewayReadinessTarget(value: unknown, enabled: boolean): MessageGatewayReadinessTarget | undefined {
  if (value === undefined) {
    if (enabled) throw new Error("message-gateway-readiness.target must be an object when enabled");
    return undefined;
  }
  const input = requiredObject(value, "message-gateway-readiness.target");
  const timeout = input.timeout_ms === undefined
    ? undefined
    : requiredPositiveInteger(input.timeout_ms, "message-gateway-readiness.target.timeout_ms");
  if (timeout !== undefined && timeout > 2000) {
    throw new Error("message-gateway-readiness.target.timeout_ms must not exceed 2000");
  }
  return {
    url: requiredLoopbackHttpUrl(input.url, "message-gateway-readiness.target.url"),
    timeout_ms: timeout
  };
}

function parseCustomJsonFiles(value: unknown): CustomJsonFileConfig[] {
  if (!Array.isArray(value)) throw new Error("custom-json.files must be an array");
  return value.map((item, index) => {
    const input = requiredObject(item, `custom-json.files[${index}]`);
    const file = requiredString(input.path, `custom-json.files[${index}].path`);
    if (/^https?:\/\//i.test(file)) throw new Error("custom-json file paths must be local paths");
    return {
      name: requiredString(input.name, `custom-json.files[${index}].name`),
      path: file
    };
  });
}

function parseStringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value)) throw new Error(`${field} must be an array`);
  return value.map((item, index) => requiredString(item, `${field}[${index}]`));
}

function requiredObject(value: unknown, field: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${field} must be an object`);
  return value as Record<string, unknown>;
}

function requiredHttpMethod(value: unknown, field: string): "GET" | "HEAD" {
  if (value === "GET" || value === "HEAD") return value;
  throw new Error(`${field} must be GET or HEAD`);
}

function requiredHttpStatus(value: unknown, field: string): number {
  if (!Number.isInteger(value) || (value as number) < 100 || (value as number) > 599) throw new Error(`${field} must be an HTTP status code`);
  return value as number;
}

function requiredHttpUrl(value: unknown, field: string): string {
  const url = requiredString(value, field);
  const parsed = new URL(url);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new Error(`${field} must be http or https`);
  return url;
}

function requiredLoopbackHttpUrl(value: unknown, field: string): string {
  const url = requiredHttpUrl(value, field);
  const parsed = new URL(url);
  if (!['127.0.0.1', 'localhost', '[::1]', '::1'].includes(parsed.hostname)) {
    throw new Error(`${field} must use a loopback host`);
  }
  return url;
}

function requiredPort(value: unknown, field: string): number {
  if (!Number.isInteger(value) || (value as number) < 1 || (value as number) > 65535) throw new Error(`${field} must be an integer from 1 to 65535`);
  return value as number;
}
