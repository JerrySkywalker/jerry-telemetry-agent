import type { Config } from "../../config.js";
import { CodexUsageCollectionError } from "./auth-provider.js";

export async function fetchCodexUsage(config: Pick<Config, "codexUsageEndpoint">, accessToken: string): Promise<unknown> {
  let response: Response;
  try {
    response = await fetch(config.codexUsageEndpoint, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        Accept: "application/json",
        "User-Agent": "jerry-telemetry-agent/0.1 codex-backend-usage"
      },
      signal: AbortSignal.timeout(15_000)
    });
  } catch {
    throw new CodexUsageCollectionError("network_error", "Codex usage backend request failed");
  }

  if (!response.ok) {
    if (response.status === 401) throw new CodexUsageCollectionError("http_401", "Codex usage backend returned HTTP 401");
    if (response.status === 403) throw new CodexUsageCollectionError("http_403", "Codex usage backend returned HTTP 403");
    if (response.status === 404) throw new CodexUsageCollectionError("http_404", "Codex usage backend returned HTTP 404");
    if (response.status === 429) throw new CodexUsageCollectionError("http_429", "Codex usage backend returned HTTP 429");
    if (response.status >= 500) throw new CodexUsageCollectionError("http_5xx", `Codex usage backend returned HTTP ${response.status}`);
    throw new CodexUsageCollectionError("network_error", `Codex usage backend returned HTTP ${response.status}`);
  }

  try {
    return await response.json();
  } catch {
    throw new CodexUsageCollectionError("schema_error", "Codex usage backend returned invalid JSON");
  }
}
