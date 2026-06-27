import { pathToFileURL } from "node:url";
import type http from "node:http";
import { loadConfig, type Config } from "./config.js";
import { startHealthServer } from "./health/server.js";
import { logger } from "./logger.js";
import { runServerDaemon } from "./serverDaemon.js";
import { buildServerStatusSummary } from "./serverStatus.js";
import { countAllSpooledPayloads, countSpooledBatches } from "./telemetry/spool.js";
import { readState } from "./telemetry/state.js";
import { sanitizeErrorForTelemetry } from "./telemetry/sanitize.js";

interface ParsedServerDaemonArgs {
  config: Config;
  maxIterations?: number;
  status: boolean;
}

function readFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

function hasFlag(args: string[], name: string): boolean {
  return args.includes(name);
}

export function parseServerDaemonArgs(env: NodeJS.ProcessEnv = process.env, args = process.argv.slice(2)): ParsedServerDaemonArgs {
  const patched: NodeJS.ProcessEnv = { ...env };
  patched.AGENT_MODE = "daemon";
  patched.TELEMETRY_NODE_CONFIG_PATH = readFlag(args, "--config") ?? env.TELEMETRY_NODE_CONFIG_PATH ?? "deploy/examples/general-linux-agent.node.json";
  patched.TELEMETRY_OUTPUT_MODE = outputMode(readFlag(args, "--output-mode") ?? env.TELEMETRY_OUTPUT_MODE ?? "file");
  patched.TELEMETRY_SERVER_BATCH_LATEST_FILE =
    readFlag(args, "--latest-file") ?? env.TELEMETRY_SERVER_BATCH_LATEST_FILE ?? ".smoke/server-daemon/server.batch.latest.safe.json";
  patched.TELEMETRY_BATCH_OUTPUT_FILE =
    readFlag(args, "--out-file") ?? env.TELEMETRY_BATCH_OUTPUT_FILE ?? patched.TELEMETRY_SERVER_BATCH_LATEST_FILE;
  patched.STATE_PATH = readFlag(args, "--state-path") ?? env.STATE_PATH ?? ".smoke/server-daemon/agent-state.json";
  patched.SPOOL_DIR = readFlag(args, "--spool-dir") ?? env.SPOOL_DIR ?? ".smoke/server-daemon/spool";
  patched.AGENT_INTERVAL_SECONDS = readFlag(args, "--interval-seconds") ?? env.AGENT_INTERVAL_SECONDS ?? "60";
  patched.TELEMETRY_HUB_URL = readFlag(args, "--hub-url") ?? env.TELEMETRY_HUB_URL ?? "";
  patched.TELEMETRY_HUB_BATCH_URL = readFlag(args, "--hub-batch-url") ?? env.TELEMETRY_HUB_BATCH_URL ?? "";
  patched.TELEMETRY_NODE_SECRET = readFlag(args, "--write-secret") ?? env.TELEMETRY_NODE_SECRET ?? "";
  patched.TELEMETRY_NODE_KEY_ID = readFlag(args, "--key-id") ?? env.TELEMETRY_NODE_KEY_ID ?? "";
  patched.SPOOL_MAX_FILES = readFlag(args, "--spool-max-files") ?? env.SPOOL_MAX_FILES ?? "100";
  patched.SPOOL_MAX_BYTES = readFlag(args, "--spool-max-bytes") ?? env.SPOOL_MAX_BYTES ?? String(10 * 1024 * 1024);
  if (hasFlag(args, "--health-server")) patched.HEALTH_SERVER_ENABLED = "true";
  patched.HEALTH_HOST = readFlag(args, "--health-host") ?? env.HEALTH_HOST ?? "127.0.0.1";
  patched.HEALTH_PORT = readFlag(args, "--health-port") ?? env.HEALTH_PORT ?? "8081";

  return {
    config: loadConfig(patched, ["--daemon"]),
    maxIterations: optionalPositiveInt(readFlag(args, "--max-iterations") ?? env.SERVER_DAEMON_MAX_ITERATIONS),
    status: hasFlag(args, "--status")
  };
}

async function main(): Promise<void> {
  const parsed = parseServerDaemonArgs();
  if (parsed.status) {
    await printStatus(parsed.config);
    return;
  }

  const controller = new AbortController();
  const abort = () => controller.abort();
  process.once("SIGINT", abort);
  process.once("SIGTERM", abort);

  let healthServer: http.Server | undefined;
  if (parsed.config.healthServerEnabled) {
    healthServer = startHealthServer(parsed.config);
    logger.info("server daemon health server started", { host: parsed.config.healthHost, port: parsed.config.healthPort });
  }

  try {
    const result = await runServerDaemon(parsed.config, { maxIterations: parsed.maxIterations, signal: controller.signal });
    logger.info("server daemon stopped", result);
  } finally {
    healthServer?.close();
  }
}

async function printStatus(config: Config): Promise<void> {
  const state = await readState(config.statePath);
  const [pendingSpoolCount, pendingBatchSpoolCount] = await Promise.all([countAllSpooledPayloads(config.spoolDir), countSpooledBatches(config.spoolDir)]);
  const summary = buildServerStatusSummary(config, state, { pendingSpoolCount, pendingBatchSpoolCount });
  console.log(JSON.stringify({
    daemon_started: Boolean(summary.daemon_started_at),
    daemon_started_at: summary.daemon_started_at,
    last_batch_captured_at: summary.last_batch_captured_at,
    last_batch_events_count: summary.last_batch_events_count,
    last_batch_successful_send_at: summary.last_batch_successful_send_at,
    last_batch_http_error_at: summary.last_batch_http_error_at,
    last_batch_error_present: summary.last_batch_error_present,
    pending_spool_count: summary.pending_spool_count,
    pending_batch_spool_count: summary.pending_batch_spool_count
  }, null, 2));
}

function outputMode(value: string): string {
  const normalized = value.toLowerCase();
  if (normalized === "fileonly") return "file";
  if (normalized === "push") return "file,http";
  return normalized;
}

function optionalPositiveInt(value: string | undefined): number | undefined {
  if (value === undefined || value.trim() === "") return undefined;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    const safe = sanitizeErrorForTelemetry(error, "server_daemon_error");
    console.error(`error=${safe.message}`);
    process.exitCode = 1;
  });
}
