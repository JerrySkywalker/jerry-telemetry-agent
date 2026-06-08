import type { Config } from "../../config.js";
import { CodexUsageCollectionError } from "./auth-provider.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function fetchCodexUsage(config: Pick<Config, "codexUsageEndpoint">, accessToken: string): Promise<unknown> {
  const endpointFamily = "wham_usage" as const;
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
  } catch (error) {
    if (process.platform === "win32" && process.env.CODEX_USAGE_DISABLE_POWERSHELL_FALLBACK !== "true") {
      return fetchCodexUsageWithPowerShell(config, accessToken);
    }
    throw new CodexUsageCollectionError("network_error", "Codex usage backend request failed", { endpointFamily });
  }

  if (!response.ok) {
    const diagnostics = { httpStatus: response.status, endpointFamily };
    if (response.status === 401) throw new CodexUsageCollectionError("http_401", "Codex usage backend returned HTTP 401", diagnostics);
    if (response.status === 403) throw new CodexUsageCollectionError("http_403", "Codex usage backend returned HTTP 403", diagnostics);
    if (response.status === 404) throw new CodexUsageCollectionError("http_404", "Codex usage backend returned HTTP 404", diagnostics);
    if (response.status === 429) throw new CodexUsageCollectionError("http_429", "Codex usage backend returned HTTP 429", diagnostics);
    if (response.status >= 500) throw new CodexUsageCollectionError("http_5xx", `Codex usage backend returned HTTP ${response.status}`, diagnostics);
    throw new CodexUsageCollectionError("network_error", `Codex usage backend returned HTTP ${response.status}`, diagnostics);
  }

  try {
    return await response.json();
  } catch {
    throw new CodexUsageCollectionError("schema_error", "Codex usage backend returned invalid JSON", { endpointFamily });
  }
}

async function fetchCodexUsageWithPowerShell(config: Pick<Config, "codexUsageEndpoint">, accessToken: string): Promise<unknown> {
  const endpointFamily = "wham_usage" as const;
  const script = `
$ErrorActionPreference = "Stop"
$headers = @{
  Authorization = "Bearer $env:CODEX_USAGE_ACCESS_TOKEN"
  Accept = "application/json"
  "User-Agent" = "jerry-telemetry-agent/0.1 codex-backend-usage"
}
try {
  $data = Invoke-RestMethod -Uri $env:CODEX_USAGE_ENDPOINT -Headers $headers -Method GET -TimeoutSec 20
  [pscustomobject]@{ ok = $true; data = $data } | ConvertTo-Json -Depth 50 -Compress
} catch {
  $response = $_.Exception.Response
  $status = if ($response) { [int]$response.StatusCode } else { $null }
  [pscustomobject]@{ ok = $false; status = $status } | ConvertTo-Json -Depth 10 -Compress
}
`;

  let stdout: string;
  try {
    const result = await execFileAsync("powershell", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script], {
      timeout: 30_000,
      maxBuffer: 1024 * 1024 * 5,
      env: {
        ...process.env,
        CODEX_USAGE_ENDPOINT: config.codexUsageEndpoint,
        CODEX_USAGE_ACCESS_TOKEN: accessToken
      }
    });
    stdout = result.stdout;
  } catch {
    throw new CodexUsageCollectionError("network_error", "Codex usage backend request failed", { endpointFamily });
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new CodexUsageCollectionError("schema_error", "Codex usage backend returned invalid JSON", { endpointFamily });
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new CodexUsageCollectionError("schema_error", "Codex usage backend returned invalid JSON", { endpointFamily });
  }

  const envelope = parsed as Record<string, unknown>;
  if (envelope.ok === true) return envelope.data;

  const status = typeof envelope.status === "number" ? envelope.status : undefined;
  const diagnostics = { httpStatus: status, endpointFamily };
  if (status === 401) throw new CodexUsageCollectionError("http_401", "Codex usage backend returned HTTP 401", diagnostics);
  if (status === 403) throw new CodexUsageCollectionError("http_403", "Codex usage backend returned HTTP 403", diagnostics);
  if (status === 404) throw new CodexUsageCollectionError("http_404", "Codex usage backend returned HTTP 404", diagnostics);
  if (status === 429) throw new CodexUsageCollectionError("http_429", "Codex usage backend returned HTTP 429", diagnostics);
  if (status !== undefined && status >= 500) throw new CodexUsageCollectionError("http_5xx", `Codex usage backend returned HTTP ${status}`, diagnostics);
  throw new CodexUsageCollectionError("network_error", "Codex usage backend request failed", { endpointFamily });
}
