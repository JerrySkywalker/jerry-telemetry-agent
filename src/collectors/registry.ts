export type CollectorName = "codex-backend-usage" | "codex-cli-status-fallback" | "agent-health";
export type UsageCollectorName = Exclude<CollectorName, "agent-health">;
export type CollectorEventType = "codex.usage.snapshot" | "telemetry.agent.health";

export interface CollectorDefinition<N extends CollectorName = CollectorName> {
  name: N;
  eventType: CollectorEventType;
  payloadKind: "codex-usage" | "agent-health";
  implemented: boolean;
}

export interface BaseCollectorConfig<N extends CollectorName = CollectorName> {
  name: N;
  enabled: boolean;
  interval_seconds?: number;
}

export type NodeCollectorConfig =
  | BaseCollectorConfig<"codex-backend-usage">
  | BaseCollectorConfig<"codex-cli-status-fallback">
  | BaseCollectorConfig<"agent-health">;

export interface DeclarativeNodeConfig {
  node_id?: string;
  hostname?: string;
  region?: string;
  role?: string;
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
  }
} satisfies Record<CollectorName, CollectorDefinition>;

const collectorNames = new Set<CollectorName>(Object.keys(collectorRegistry) as CollectorName[]);

export function assertCollectorName(value: string | undefined): CollectorName {
  if (value && collectorNames.has(value as CollectorName)) return value as CollectorName;
  throw new Error(`Invalid collector name: ${value ?? ""}`);
}

export function assertUsageCollectorName(value: string | undefined): UsageCollectorName {
  const name = assertCollectorName(value);
  if (name === "agent-health") throw new Error("agent-health is not a usage collector");
  return name;
}

export function isUsageCollectorName(name: CollectorName): name is UsageCollectorName {
  return name !== "agent-health";
}

export function collectorEventType(name: CollectorName): CollectorEventType {
  return collectorRegistry[name].eventType;
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
  return interval === undefined ? { name, enabled } : { name, enabled, interval_seconds: interval };
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
