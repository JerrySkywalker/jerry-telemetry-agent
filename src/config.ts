import os from "node:os";
import path from "node:path";
import { readFileSync } from "node:fs";
import {
  assertCollectorName,
  activeUsageCollectorFromConfig,
  defaultCollectorConfigs,
  isUsageCollectorName,
  parseDeclarativeNodeConfig,
  type CollectorName,
  type DeclarativeNodeConfig,
  type NodeCollectorConfig,
  type UsageCollectorName
} from "./collectors/registry.js";

export type AgentMode = "once" | "daemon";
export type ProviderMode = "backend-usage" | "file" | "host-codex" | "container-codex";
export type CollectorMode = CollectorName;
export type OutputMode = "stdout" | "file" | "http";

export interface Config {
  mode: AgentMode;
  dryRun: boolean;
  provider: ProviderMode;
  outputModes: OutputMode[];
  intervalSeconds: number;
  codexHome: string;
  codexUsageEndpoint: string;
  codexStatusLatestPath: string;
  hostCodexBin: string;
  hostCodexHome: string;
  codexTmuxSession: string;
  hubUrl: string;
  hubBatchUrl: string;
  nodeId: string;
  nodeSecret: string;
  nodeKeyId: string;
  hostname: string;
  region: string;
  collector: CollectorName;
  collectorMode: CollectorMode;
  collectorConfigs: NodeCollectorConfig[];
  nodeConfigPath: string;
  accountLabel: string;
  nodeRole: string;
  platform: string;
  outputFile: string;
  usageLatestPath: string;
  usageLastGoodPath: string;
  serverBatchLatestFile: string;
  serverBatchOutputFile: string;
  statePath: string;
  spoolDir: string;
  spoolMaxFiles: number;
  spoolMaxBytes: number;
  forceSend: boolean;
  healthServerEnabled: boolean;
  healthHost: string;
  healthPort: number;
  agentHealthEnabled: boolean;
  agentHealthEventType: "telemetry.agent.health";
  agentHealthIntervalSeconds: number;
  agentHealthOutputFile: string;
}

export function defaultCodexHome(env: NodeJS.ProcessEnv = process.env, platform = process.platform, homeDir = os.homedir()): string {
  if (env.CODEX_HOME) return env.CODEX_HOME;
  if (platform === "win32") {
    const userProfile = env.USERPROFILE;
    if (userProfile) return path.win32.join(userProfile, ".codex");
  }
  return path.join(homeDir, ".codex");
}

function bool(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}

function int(value: string | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function readFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index === -1) return undefined;
  return args[index + 1];
}

function hasFlag(args: string[], name: string): boolean {
  return args.includes(name);
}

function provider(value: string | undefined): ProviderMode {
  if (value === "backend-usage" || value === "file" || value === "host-codex" || value === "container-codex") return value;
  throw new Error(`Invalid CODEX_PROVIDER: ${value ?? ""}`);
}

function outputModes(value: string | undefined): OutputMode[] {
  const raw = value ?? "stdout";
  const modes = raw.split(",").map((item) => item.trim()).filter(Boolean);
  const valid = new Set(["stdout", "file", "http"]);
  for (const mode of modes) {
    if (!valid.has(mode)) throw new Error(`Invalid TELEMETRY_OUTPUT_MODE: ${mode}`);
  }
  return [...new Set(modes)] as OutputMode[];
}

function mode(value: string | undefined): AgentMode {
  if (value === "once" || value === "daemon") return value;
  throw new Error(`Invalid AGENT_MODE: ${value ?? ""}`);
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env, args = process.argv.slice(2)): Config {
  const cliProvider = readFlag(args, "--provider");
  const cliCollector = readFlag(args, "--collector");
  const cliMode = hasFlag(args, "--once") ? "once" : hasFlag(args, "--daemon") ? "daemon" : undefined;
  const nodeConfig = loadDeclarativeConfig(env.TELEMETRY_NODE_CONFIG_PATH);
  const configuredUsageCollector = activeUsageCollectorFromConfig(nodeConfig?.collectors);
  const collectorMode = assertCollectorName(
    cliCollector ??
      env.TELEMETRY_COLLECTOR_MODE ??
      configuredUsageCollector ??
      (nodeConfig?.collectors ? "agent-health" : bool(env.TELEMETRY_ENABLE_TMUX_FALLBACK, false) ? "codex-cli-status-fallback" : "codex-backend-usage")
  );
  const statePath = env.STATE_PATH ?? "/state/agent-state.json";
  const agentMode = mode(cliMode ?? env.AGENT_MODE ?? "daemon");
  const configAgentHealth = nodeConfig?.collectors?.find((item) => item.name === "agent-health")?.enabled;
  const agentHealthDefault = configAgentHealth ?? (agentMode === "daemon" || hasFlag(args, "--health"));
  const intervalSeconds = int(env.CODEX_USAGE_POLL_INTERVAL_SECONDS ?? env.AGENT_INTERVAL_SECONDS, 300);
  const agentHealthEnabled = hasFlag(args, "--no-health") ? false : bool(env.TELEMETRY_AGENT_HEALTH_ENABLED, agentHealthDefault);

  return {
    mode: agentMode,
    dryRun: hasFlag(args, "--dry-run") || bool(env.DRY_RUN, false),
    provider: provider(cliProvider ?? env.CODEX_PROVIDER ?? "backend-usage"),
    outputModes: outputModes(env.TELEMETRY_OUTPUT_MODE),
    intervalSeconds,
    codexHome: defaultCodexHome(env),
    codexUsageEndpoint: env.CODEX_USAGE_ENDPOINT ?? "https://chatgpt.com/backend-api/wham/usage",
    codexStatusLatestPath: env.CODEX_STATUS_LATEST_PATH ?? "/input/latest.json",
    hostCodexBin: env.HOST_CODEX_BIN ?? "/host-bin/codex",
    hostCodexHome: env.HOST_CODEX_HOME ?? "/host-codex-home",
    codexTmuxSession: env.CODEX_TMUX_SESSION ?? "codex-status-agent",
    hubUrl: env.TELEMETRY_HUB_URL ?? "",
    hubBatchUrl: env.TELEMETRY_HUB_BATCH_URL ?? "",
    nodeId: env.TELEMETRY_NODE_ID ?? nodeConfig?.node_id ?? "",
    nodeSecret: env.TELEMETRY_NODE_SECRET ?? "",
    nodeKeyId: env.TELEMETRY_NODE_KEY_ID ?? "",
    hostname: env.TELEMETRY_HOSTNAME ?? nodeConfig?.hostname ?? os.hostname(),
    region: env.TELEMETRY_REGION ?? nodeConfig?.region ?? "",
    collector: assertCollectorName(env.TELEMETRY_COLLECTOR ?? collectorMode),
    collectorMode,
    collectorConfigs: nodeConfig?.collectors ?? (isUsageCollectorName(collectorMode)
      ? defaultCollectorConfigs(collectorMode, intervalSeconds, agentHealthEnabled)
      : [{ name: collectorMode, enabled: true, interval_seconds: intervalSeconds }]),
    nodeConfigPath: env.TELEMETRY_NODE_CONFIG_PATH ?? "",
    accountLabel: env.TELEMETRY_ACCOUNT_LABEL ?? "",
    nodeRole: env.TELEMETRY_NODE_ROLE ?? nodeConfig?.role ?? "",
    platform: process.platform,
    outputFile: env.TELEMETRY_OUTPUT_FILE ?? "/state/codex-usage-latest.safe.snapshot.json",
    usageLatestPath: env.CODEX_USAGE_LATEST_PATH ?? "/state/codex-usage-latest.safe.snapshot.json",
    usageLastGoodPath: env.CODEX_USAGE_LAST_GOOD_PATH ?? "/state/codex-usage-last-good.safe.snapshot.json",
    serverBatchLatestFile: env.TELEMETRY_SERVER_BATCH_LATEST_FILE ?? env.TELEMETRY_BATCH_OUTPUT_FILE ?? "/state/server-batch-latest.safe.json",
    serverBatchOutputFile: env.TELEMETRY_BATCH_OUTPUT_FILE ?? env.TELEMETRY_SERVER_BATCH_LATEST_FILE ?? "/state/server-batch.safe.json",
    statePath,
    spoolDir: env.SPOOL_DIR ?? "/state/spool",
    spoolMaxFiles: int(env.SPOOL_MAX_FILES, 100),
    spoolMaxBytes: int(env.SPOOL_MAX_BYTES, 10 * 1024 * 1024),
    forceSend: bool(env.FORCE_SEND, false),
    healthServerEnabled: bool(env.HEALTH_SERVER_ENABLED, false),
    healthHost: env.HEALTH_HOST ?? "0.0.0.0",
    healthPort: int(env.HEALTH_PORT, 8081),
    agentHealthEnabled,
    agentHealthEventType: "telemetry.agent.health",
    agentHealthIntervalSeconds: int(env.TELEMETRY_AGENT_HEALTH_INTERVAL_SECONDS, int(env.CODEX_USAGE_POLL_INTERVAL_SECONDS ?? env.AGENT_INTERVAL_SECONDS, 300)),
    agentHealthOutputFile: env.TELEMETRY_AGENT_HEALTH_OUTPUT_FILE ?? "/state/agent-health-latest.safe.snapshot.json"
  };
}

function loadDeclarativeConfig(file: string | undefined): DeclarativeNodeConfig | undefined {
  if (!file) return undefined;
  return parseDeclarativeNodeConfig(JSON.parse(readFileSync(file, "utf8")) as unknown);
}

export function assertUploadConfig(config: Config): void {
  if (config.dryRun) return;
  const missing = [
    ["TELEMETRY_HUB_URL", config.hubUrl],
    ["TELEMETRY_NODE_ID", config.nodeId],
    ["TELEMETRY_NODE_SECRET", config.nodeSecret]
  ].filter(([, value]) => !value);
  if (missing.length > 0) {
    throw new Error(`Missing required upload config: ${missing.map(([key]) => key).join(", ")}`);
  }
}
