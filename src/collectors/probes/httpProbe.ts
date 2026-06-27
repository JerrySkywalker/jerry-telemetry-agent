import type { HttpProbeTarget } from "../registry.js";
import type { ServerStatus } from "../serverTypes.js";
import { findForbiddenTelemetryMarkers } from "../../telemetry/forbiddenMarkers.js";
import { sanitizeTelemetryString } from "../../telemetry/sanitize.js";

export interface HttpProbeResult {
  name: string;
  kind: "http";
  status: ServerStatus;
  last_check: string;
  response_time_ms: number | null;
  status_code: number | null;
  sanitized_url: string;
  message: string;
}

export async function collectHttpProbes(targets: HttpProbeTarget[], capturedAt: string, fetchImpl: typeof fetch = fetch): Promise<Record<string, unknown>> {
  return {
    services: await Promise.all(targets.map((target) => runHttpProbe(target, capturedAt, fetchImpl)))
  };
}

export async function runHttpProbe(target: HttpProbeTarget, capturedAt: string, fetchImpl: typeof fetch = fetch): Promise<HttpProbeResult> {
  const started = Date.now();
  const timeoutMs = target.timeout_ms ?? 2000;
  const sanitizedUrl = sanitizeProbeUrl(target.url);

  try {
    const response = await fetchImpl(target.url, {
      method: target.method ?? "GET",
      redirect: "manual",
      signal: AbortSignal.timeout(timeoutMs)
    });
    const elapsed = Date.now() - started;
    const expectedStatus = target.expected_status ?? (response.status >= 200 && response.status < 400 ? response.status : 200);
    const healthy = response.status === expectedStatus;
    return {
      name: safeName(target.name),
      kind: "http",
      status: healthy ? "healthy" : response.status >= 500 ? "down" : "degraded",
      last_check: capturedAt,
      response_time_ms: elapsed,
      status_code: response.status,
      sanitized_url: sanitizedUrl,
      message: healthy ? "http probe healthy" : `http probe returned HTTP ${response.status}`
    };
  } catch {
    return {
      name: safeName(target.name),
      kind: "http",
      status: "down",
      last_check: capturedAt,
      response_time_ms: Date.now() - started,
      status_code: null,
      sanitized_url: sanitizedUrl,
      message: "http probe failed"
    };
  }
}

export function sanitizeProbeUrl(value: string): string {
  try {
    const parsed = new URL(value);
    parsed.username = "";
    parsed.password = "";
    parsed.search = "";
    parsed.hash = "";
    const output = parsed.toString();
    return findForbiddenTelemetryMarkers(output).length > 0 ? `${parsed.protocol}//${parsed.host}${parsed.pathname}` : output;
  } catch {
    return "invalid-url";
  }
}

function safeName(value: string): string {
  const sanitized = sanitizeTelemetryString(value);
  return findForbiddenTelemetryMarkers(sanitized).length > 0 ? "redacted-target" : sanitized;
}
