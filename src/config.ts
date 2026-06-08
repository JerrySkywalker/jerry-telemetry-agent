import os from "node:os";

export type AgentMode = "once" | "daemon";
export type ProviderMode = "file" | "host-codex" | "container-codex";

export interface Config {
  mode: AgentMode;
  dryRun: boolean;
  provider: ProviderMode;
  intervalSeconds: number;
  codexStatusLatestPath: string;
  hostCodexBin: string;
  hostCodexHome: string;
  codexTmuxSession: string;
  hubUrl: string;
  nodeId: string;
  nodeSecret: string;
  hostname: string;
  region: string;
  collector: string;
  statePath: string;
  spoolDir: string;
  forceSend: boolean;
  healthServerEnabled: boolean;
  healthHost: string;
  healthPort: number;
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
  if (value === "file" || value === "host-codex" || value === "container-codex") return value;
  throw new Error(`Invalid CODEX_PROVIDER: ${value ?? ""}`);
}

function mode(value: string | undefined): AgentMode {
  if (value === "once" || value === "daemon") return value;
  throw new Error(`Invalid AGENT_MODE: ${value ?? ""}`);
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env, args = process.argv.slice(2)): Config {
  const cliProvider = readFlag(args, "--provider");
  const cliMode = hasFlag(args, "--once") ? "once" : hasFlag(args, "--daemon") ? "daemon" : undefined;

  return {
    mode: mode(cliMode ?? env.AGENT_MODE ?? "daemon"),
    dryRun: hasFlag(args, "--dry-run") || bool(env.DRY_RUN, false),
    provider: provider(cliProvider ?? env.CODEX_PROVIDER ?? "file"),
    intervalSeconds: int(env.AGENT_INTERVAL_SECONDS, 600),
    codexStatusLatestPath: env.CODEX_STATUS_LATEST_PATH ?? "/input/latest.json",
    hostCodexBin: env.HOST_CODEX_BIN ?? "/host-bin/codex",
    hostCodexHome: env.HOST_CODEX_HOME ?? "/host-codex-home",
    codexTmuxSession: env.CODEX_TMUX_SESSION ?? "codex-status-agent",
    hubUrl: env.TELEMETRY_HUB_URL ?? "",
    nodeId: env.TELEMETRY_NODE_ID ?? "",
    nodeSecret: env.TELEMETRY_NODE_SECRET ?? "",
    hostname: env.TELEMETRY_HOSTNAME ?? os.hostname(),
    region: env.TELEMETRY_REGION ?? "",
    collector: env.TELEMETRY_COLLECTOR ?? "codex-status",
    statePath: env.STATE_PATH ?? "/state/agent-state.json",
    spoolDir: env.SPOOL_DIR ?? "/state/spool",
    forceSend: bool(env.FORCE_SEND, false),
    healthServerEnabled: bool(env.HEALTH_SERVER_ENABLED, false),
    healthHost: env.HEALTH_HOST ?? "0.0.0.0",
    healthPort: int(env.HEALTH_PORT, 8081)
  };
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
