import { readFile } from "node:fs/promises";
import { buildServerTelemetryBatch } from "./collectors/serverBatch.js";
import { parseDeclarativeNodeConfig, type DeclarativeNodeConfig } from "./collectors/registry.js";
import type { Config } from "./config.js";
import { logger } from "./logger.js";
import { writeSnapshotFile } from "./sinks/fileSink.js";
import { findForbiddenTelemetryMarkers } from "./telemetry/forbiddenMarkers.js";
import {
  countAllSpooledPayloads,
  countSpooledBatches,
  enforceBatchSpoolLimits,
  listSpooledBatchFiles,
  quarantineSpooledBatch,
  readSpooledBatch,
  removeSpooledBatch,
  spoolBatch
} from "./telemetry/spool.js";
import { readState, updateState } from "./telemetry/state.js";
import { sanitizeErrorForTelemetry } from "./telemetry/sanitize.js";
import { resolveBatchHubUrl, uploadBatch } from "./telemetry/uploader.js";

export interface ServerDaemonRunOptions {
  maxIterations?: number;
  signal?: AbortSignal;
  intervalMs?: number;
}

export interface ServerDaemonRunResult {
  iterations: number;
  stopped: "max_iterations" | "signal";
}

export interface ServerDaemonIterationResult {
  captured_at: string;
  events_count: number;
  event_types: string[];
  upload: "disabled" | "ok" | "spooled" | "dry_run";
  retry: BatchRetryResult;
}

export interface BatchRetryResult {
  attempted: number;
  sent: number;
  kept: number;
  quarantined: number;
  last_error?: string;
}

export async function runServerDaemon(config: Config, options: ServerDaemonRunOptions = {}): Promise<ServerDaemonRunResult> {
  const nodeConfig = await loadServerNodeConfig(config.nodeConfigPath);
  assertServerDaemonConfig(config);
  const startedAt = new Date().toISOString();
  const collectorNames = enabledCollectorNames(nodeConfig);
  await updateServerState(config, {
    daemonStartedAt: startedAt,
    daemonMode: "server",
    nodeId: nodeConfig.node_id ?? config.nodeId,
    hostname: nodeConfig.hostname ?? config.hostname,
    collectorNames
  });

  let iterations = 0;
  while (!options.signal?.aborted) {
    const result = await runServerDaemonIteration(config, nodeConfig, startedAt);
    logServerDaemonIteration(result);
    iterations += 1;
    if (options.maxIterations !== undefined && iterations >= options.maxIterations) {
      return { iterations, stopped: "max_iterations" };
    }
    await sleep(options.intervalMs ?? config.intervalSeconds * 1000, options.signal);
  }

  return { iterations, stopped: "signal" };
}

export async function runServerDaemonIteration(
  config: Config,
  nodeConfig: DeclarativeNodeConfig,
  startedAt = new Date().toISOString()
): Promise<ServerDaemonIterationResult> {
  assertServerDaemonConfig(config);
  const retry = config.outputModes.includes("http") ? await retrySpooledBatches(config) : emptyRetryResult();
  const batch = await buildServerTelemetryBatch(nodeConfig, { httpEnabled: config.outputModes.includes("http") });
  const forbidden = findForbiddenTelemetryMarkers(batch);
  if (forbidden.length > 0) throw new Error("Server telemetry batch contains a forbidden marker");

  await writeSnapshotFile(config.serverBatchLatestFile, batch);
  if (config.outputModes.includes("file") && config.serverBatchOutputFile !== config.serverBatchLatestFile) {
    await writeSnapshotFile(config.serverBatchOutputFile, batch);
  }

  const eventTypes = [...new Set(batch.events.map((event) => event.event_type))];
  await updateServerState(config, {
    daemonStartedAt: startedAt,
    daemonMode: "server",
    nodeId: nodeConfig.node_id ?? config.nodeId,
    hostname: nodeConfig.hostname ?? config.hostname,
    collectorNames: enabledCollectorNames(nodeConfig),
    lastServerBatchCapturedAt: batch.events[0]?.captured_at ?? new Date().toISOString(),
    lastServerBatchEventTypes: eventTypes,
    lastServerBatchEventsCount: batch.events.length,
    lastServerBatchFile: config.serverBatchLatestFile
  });

  let upload: ServerDaemonIterationResult["upload"] = "disabled";
  if (config.outputModes.includes("http")) {
    if (config.dryRun) {
      upload = "dry_run";
      await updateServerState(config, {
        lastServerBatchSuccessfulSendAt: new Date().toISOString(),
        lastServerBatchError: undefined,
        lastError: undefined
      });
    } else {
      try {
        await uploadServerBatch(config, nodeConfig, batch);
        upload = "ok";
        await updateServerState(config, {
          lastServerBatchSuccessfulSendAt: new Date().toISOString(),
          lastServerBatchError: undefined,
          lastError: undefined
        });
      } catch (error) {
        upload = "spooled";
        const errorAt = new Date().toISOString();
        const safe = sanitizeErrorForTelemetry(error, "server_batch_upload_error");
        await spoolBatch(config.spoolDir, batch);
        const limits = await enforceBatchSpoolLimits(config.spoolDir, { maxFiles: config.spoolMaxFiles, maxBytes: config.spoolMaxBytes });
        await updateServerState(config, {
          lastServerBatchHttpErrorAt: errorAt,
          lastServerBatchError: limits.droppedFiles > 0 ? `${safe.message}; batch spool limit dropped oldest` : safe.message,
          lastError: safe.message
        });
      }
    }
  }

  await refreshSpoolCounts(config);
  return {
    captured_at: batch.events[0]?.captured_at ?? new Date().toISOString(),
    events_count: batch.events.length,
    event_types: eventTypes,
    upload,
    retry
  };
}

export async function retrySpooledBatches(config: Config): Promise<BatchRetryResult> {
  assertServerDaemonConfig(config);
  const result: BatchRetryResult = emptyRetryResult();
  const files = await listSpooledBatchFiles(config.spoolDir);
  for (const file of files) {
    result.attempted += 1;
    let batch;
    try {
      batch = await readSpooledBatch(file);
    } catch {
      await quarantineSpooledBatch(file);
      result.quarantined += 1;
      continue;
    }

    try {
      await uploadServerBatch(config, undefined, batch);
      await removeSpooledBatch(file);
      result.sent += 1;
      await updateServerState(config, {
        lastServerBatchSuccessfulSendAt: new Date().toISOString(),
        lastServerBatchError: undefined,
        lastError: undefined
      });
    } catch (error) {
      result.kept += 1;
      result.last_error = sanitizeErrorForTelemetry(error, "server_batch_spool_retry_error").message;
      await updateServerState(config, {
        lastServerBatchHttpErrorAt: new Date().toISOString(),
        lastServerBatchError: result.last_error,
        lastError: result.last_error
      });
      break;
    }
  }
  await refreshSpoolCounts(config);
  return result;
}

export async function loadServerNodeConfig(configPath: string): Promise<DeclarativeNodeConfig> {
  if (!configPath) throw new Error("Server daemon requires TELEMETRY_NODE_CONFIG_PATH");
  return parseDeclarativeNodeConfig(JSON.parse((await readFile(configPath, "utf8")).replace(/^\uFEFF/, "")) as unknown);
}

export function assertServerDaemonConfig(config: Config): void {
  if (!config.outputModes.includes("file") && !config.outputModes.includes("http")) {
    throw new Error("Server daemon requires TELEMETRY_OUTPUT_MODE=file, http, or file,http");
  }
  if (!config.outputModes.includes("http") || config.dryRun) return;
  const missing = [
    ["TELEMETRY_NODE_SECRET", config.nodeSecret],
    ["TELEMETRY_NODE_ID", config.nodeId]
  ].filter(([, value]) => !value);
  if (missing.length > 0) {
    throw new Error(`Missing required server batch upload config: ${missing.map(([key]) => key).join(", ")}`);
  }
  resolveBatchHubUrl({ hubUrl: config.hubUrl, hubBatchUrl: config.hubBatchUrl });
}

export async function refreshSpoolCounts(config: Config): Promise<void> {
  const [pendingSpoolCount, pendingBatchSpoolCount] = await Promise.all([countAllSpooledPayloads(config.spoolDir), countSpooledBatches(config.spoolDir)]);
  await updateState(config.statePath, { pendingSpoolCount, pendingBatchSpoolCount });
}

async function uploadServerBatch(config: Config, nodeConfig: DeclarativeNodeConfig | undefined, batch: unknown): Promise<void> {
  await uploadBatch(
    {
      hubUrl: config.hubUrl,
      hubBatchUrl: config.hubBatchUrl,
      nodeId: nodeConfig?.node_id ?? config.nodeId,
      nodeSecret: config.nodeSecret,
      nodeKeyId: config.nodeKeyId,
      timeoutMs: config.hubRequestTimeoutMs
    },
    batch
  );
}

async function updateServerState(config: Config, patch: Parameters<typeof updateState>[1]): Promise<void> {
  await updateState(config.statePath, patch);
}

function enabledCollectorNames(config: DeclarativeNodeConfig): string[] {
  return (config.collectors ?? []).filter((collector) => collector.enabled).map((collector) => collector.name);
}

function emptyRetryResult(): BatchRetryResult {
  return { attempted: 0, sent: 0, kept: 0, quarantined: 0 };
}

async function sleep(ms: number, signal: AbortSignal | undefined): Promise<void> {
  if (signal?.aborted) return;
  await new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true }
    );
  });
}

export function logServerDaemonIteration(result: ServerDaemonIterationResult): void {
  logger.info("server daemon iteration completed", {
    captured_at: result.captured_at,
    events_count: result.events_count,
    event_types: result.event_types,
    upload: result.upload,
    retry: {
      attempted: result.retry.attempted,
      sent: result.retry.sent,
      kept: result.retry.kept,
      quarantined: result.retry.quarantined,
      last_error_present: Boolean(result.retry.last_error)
    }
  });
}
