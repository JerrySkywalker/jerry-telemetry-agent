import type { Config } from "../../config.js";
import type { CodexUsageSnapshot } from "../../types/codex-usage.js";
import { HostCodexProvider } from "../../providers/hostCodexProvider.js";
import { FileProvider } from "../../providers/fileProvider.js";
import { CodexUsageCollectionError, readCodexAuth } from "./auth-provider.js";
import { fetchCodexUsage } from "./usage-client.js";
import { errorSnapshot, fallbackSnapshot, normalizeCodexUsage } from "./normalizer.js";

export async function collectCodexUsage(config: Config, lastGoodExists = false): Promise<CodexUsageSnapshot> {
  if (config.collectorMode === "codex-cli-status-fallback") {
    return collectFallback(config);
  }

  try {
    const auth = await readCodexAuth(config);
    const rawUsage = await fetchCodexUsage(config, auth.accessToken);
    return normalizeCodexUsage(rawUsage, config);
  } catch (error) {
    if (error instanceof CodexUsageCollectionError) {
      return errorSnapshot(config, error.code, error.message, new Date().toISOString(), lastGoodExists);
    }
    return errorSnapshot(config, "network_error", (error as Error).message, new Date().toISOString(), lastGoodExists);
  }
}

async function collectFallback(config: Config): Promise<CodexUsageSnapshot> {
  const provider = config.provider === "host-codex" ? new HostCodexProvider(config) : new FileProvider(config);
  const result = await provider.collect();
  return fallbackSnapshot(result.payload, config, result.capturedAt);
}
