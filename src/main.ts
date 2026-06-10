import { assertUploadConfig, loadConfig, type Config } from "./config.js";
import { pathToFileURL } from "node:url";
import { access } from "node:fs/promises";
import { logger } from "./logger.js";
import { buildEnvelope, stablePayloadHash } from "./telemetry/envelope.js";
import { readState, updateState } from "./telemetry/state.js";
import { listSpooledEvents, quarantineSpooledEvent, removeSpooledEvent, spoolEvent } from "./telemetry/spool.js";
import { uploadEvent } from "./telemetry/uploader.js";
import { startHealthServer } from "./health/server.js";
import { buildAgentHealthSnapshot } from "./health/agentHealth.js";
import { collectCodexUsage } from "./collectors/codex/index.js";
import { writeSnapshotFile } from "./sinks/fileSink.js";
import type { CodexUsageSnapshot } from "./types/codex-usage.js";

async function sendOrDryRun(config: Config, event: unknown): Promise<void> {
  if (config.dryRun) {
    logger.info("dry-run telemetry event");
    return;
  }
  await uploadEvent(config, event);
}

async function retrySpool(config: Config): Promise<void> {
  const events = await listSpooledEvents(config.spoolDir);
  for (const item of events) {
    try {
      await sendOrDryRun(config, item.event);
      await removeSpooledEvent(item.path);
      await updateState(config.statePath, { lastSuccessfulSendAt: new Date().toISOString(), lastError: undefined });
    } catch (error) {
      if (error instanceof SyntaxError) {
        await quarantineSpooledEvent(item.path);
      }
      throw error;
    }
  }
}

export async function runOnce(config: Config): Promise<void> {
  let latestUsage: CodexUsageSnapshot | undefined;
  let usageError: unknown;
  let lastHttpErrorAt: string | undefined;

  try {
    if (config.outputModes.includes("http")) {
      assertUploadConfig(config);
      await retrySpool(config);
    }
    const state = await readState(config.statePath);
    const snapshot = await collectCodexUsage(config, Boolean(state.lastSuccessfulUsageAt) || (await fileExists(config.usageLastGoodPath)));
    latestUsage = snapshot;
    const hash = stablePayloadHash(snapshot);

    await writeSnapshotFile(config.usageLatestPath, snapshot);
    if (snapshot.status.ok) {
      await writeSnapshotFile(config.usageLastGoodPath, snapshot);
    }
    if (config.outputModes.includes("file")) {
      await writeSnapshotFile(config.outputFile, snapshot);
    }
    if (config.outputModes.includes("stdout")) {
      process.stdout.write(`${JSON.stringify(snapshot)}\n`);
    }

    if (!config.forceSend && state.lastPayloadHash === hash) {
      logger.info("skipping unchanged codex usage snapshot", { observedAt: snapshot.observed_at });
      await updateState(config.statePath, {
        lastPayloadCapturedAt: snapshot.observed_at,
        lastError: undefined
      });
      return;
    }

    if (!config.outputModes.includes("http")) {
      await updateState(config.statePath, {
        lastPayloadCapturedAt: snapshot.observed_at,
        lastPayloadHash: hash,
        lastSuccessfulUsageAt: snapshot.status.ok ? snapshot.observed_at : state.lastSuccessfulUsageAt,
        lastError: snapshot.status.ok ? undefined : snapshot.status.message
      });
      return;
    }

    const event = buildEnvelope(config, snapshot as unknown as Record<string, unknown>, snapshot.observed_at);
    try {
      await sendOrDryRun(config, event);
      await updateState(config.statePath, {
        lastPayloadCapturedAt: snapshot.observed_at,
        lastPayloadHash: hash,
        lastSuccessfulUsageAt: snapshot.status.ok ? snapshot.observed_at : state.lastSuccessfulUsageAt,
        lastSuccessfulSendAt: new Date().toISOString(),
        lastError: undefined
      });
    } catch (error) {
      lastHttpErrorAt = new Date().toISOString();
      await spoolEvent(config.spoolDir, event);
      await updateState(config.statePath, {
        lastPayloadCapturedAt: snapshot.observed_at,
        lastPayloadHash: hash,
        lastSuccessfulUsageAt: snapshot.status.ok ? snapshot.observed_at : state.lastSuccessfulUsageAt,
        lastHttpErrorAt,
        lastError: (error as Error).message
      });
      throw error;
    }
  } catch (error) {
    usageError = error;
    throw error;
  } finally {
    if (config.agentHealthEnabled) {
      await emitAgentHealth(config, latestUsage, usageError, lastHttpErrorAt);
    }
  }
}

async function emitAgentHealth(config: Config, latestUsage?: CodexUsageSnapshot, usageError?: unknown, lastHttpErrorAt?: string): Promise<void> {
  try {
    const state = await readState(config.statePath);
    const collectorErrorCode = latestUsage?.status.error_code ?? (usageError ? "agent_iteration_error" : null);
    const collectorErrorAt = collectorErrorCode ? new Date().toISOString() : null;
    const snapshot = await buildAgentHealthSnapshot(config, { state, latestUsage, collectorErrorCode, collectorErrorAt, lastHttpErrorAt });
    await writeSnapshotFile(config.agentHealthOutputFile, snapshot);

    if (!config.outputModes.includes("http")) {
      await updateState(config.statePath, { lastHealthEventAt: snapshot.observed_at });
      return;
    }

    const event = buildEnvelope(config, snapshot as unknown as Record<string, unknown>, snapshot.observed_at);
    try {
      await sendOrDryRun(config, event);
      await updateState(config.statePath, {
        lastHealthEventAt: snapshot.observed_at,
        lastSuccessfulHealthSendAt: new Date().toISOString(),
        lastSuccessfulSendAt: new Date().toISOString(),
        lastError: state.lastError
      });
    } catch (error) {
      const errorAt = new Date().toISOString();
      await spoolEvent(config.spoolDir, event);
      await updateState(config.statePath, {
        lastHealthEventAt: snapshot.observed_at,
        lastHttpErrorAt: errorAt,
        lastError: state.lastError
      });
      logger.error("agent health event upload failed", { error: (error as Error).message });
    }
  } catch (error) {
    logger.error("agent health event failed", { error: (error as Error).message });
  }
}

async function fileExists(file: string): Promise<boolean> {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function main(): Promise<void> {
  const config = loadConfig();
  if (process.argv.includes("--status")) {
    const state = await readState(config.statePath);
    console.log(JSON.stringify({ collector: config.collectorMode, provider: config.provider, node_id: config.nodeId, hostname: config.hostname, state }, null, 2));
    return;
  }

  if (config.healthServerEnabled) {
    startHealthServer(config);
    logger.info("health server started", { host: config.healthHost, port: config.healthPort });
  }

  if (config.mode === "once") {
    await runOnce(config);
    return;
  }

  logger.info("agent daemon started", { collector: config.collectorMode, outputModes: config.outputModes, intervalSeconds: config.intervalSeconds });
  for (;;) {
    try {
      await runOnce(config);
    } catch (error) {
      logger.error("agent iteration failed", { error: (error as Error).message });
    }
    await new Promise((resolve) => setTimeout(resolve, config.intervalSeconds * 1000));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    logger.error("agent failed", { error: (error as Error).message });
    process.exitCode = 1;
  });
}
