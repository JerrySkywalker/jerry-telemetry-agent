import { assertUploadConfig, loadConfig, type Config } from "./config.js";
import { pathToFileURL } from "node:url";
import { logger } from "./logger.js";
import { FileProvider } from "./providers/fileProvider.js";
import { HostCodexProvider } from "./providers/hostCodexProvider.js";
import type { CodexProvider } from "./providers/provider.js";
import { buildEnvelope, stablePayloadHash } from "./telemetry/envelope.js";
import { readState, updateState } from "./telemetry/state.js";
import { listSpooledEvents, quarantineSpooledEvent, removeSpooledEvent, spoolEvent } from "./telemetry/spool.js";
import { uploadEvent } from "./telemetry/uploader.js";
import { startHealthServer } from "./health/server.js";

function createProvider(config: Config): CodexProvider {
  if (config.provider === "file") return new FileProvider(config);
  if (config.provider === "host-codex") return new HostCodexProvider(config);
  throw new Error("container-codex provider is reserved and not implemented yet");
}

async function sendOrDryRun(config: Config, event: unknown): Promise<void> {
  if (config.dryRun) {
    logger.info("dry-run telemetry event", { event });
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
  assertUploadConfig(config);
  await retrySpool(config);
  const provider = createProvider(config);
  const result = await provider.collect();
  const hash = stablePayloadHash(result.payload);
  const state = await readState(config.statePath);

  if (!config.forceSend && state.lastPayloadHash === hash) {
    logger.info("skipping unchanged codex status", { capturedAt: result.capturedAt });
    await updateState(config.statePath, {
      lastPayloadCapturedAt: result.capturedAt,
      lastSourceFile: result.sourceFile,
      lastError: undefined
    });
    return;
  }

  const event = buildEnvelope(config, result.payload, new Date().toISOString());
  try {
    await sendOrDryRun(config, event);
    await updateState(config.statePath, {
      lastPayloadCapturedAt: result.capturedAt,
      lastPayloadHash: hash,
      lastSourceFile: result.sourceFile,
      lastSuccessfulSendAt: new Date().toISOString(),
      lastError: undefined
    });
  } catch (error) {
    await spoolEvent(config.spoolDir, event);
    await updateState(config.statePath, {
      lastPayloadCapturedAt: result.capturedAt,
      lastPayloadHash: hash,
      lastSourceFile: result.sourceFile,
      lastError: (error as Error).message
    });
    throw error;
  }
}

async function main(): Promise<void> {
  const config = loadConfig();
  if (process.argv.includes("--status")) {
    const state = await readState(config.statePath);
    console.log(JSON.stringify({ provider: config.provider, node_id: config.nodeId, hostname: config.hostname, state }, null, 2));
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

  logger.info("agent daemon started", { provider: config.provider, intervalSeconds: config.intervalSeconds });
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
