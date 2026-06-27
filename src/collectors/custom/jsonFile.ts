import { readFile, stat } from "node:fs/promises";
import type { CustomJsonFileConfig } from "../registry.js";
import { findForbiddenTelemetryMarkers } from "../../telemetry/forbiddenMarkers.js";
import { sanitizeTelemetryString } from "../../telemetry/sanitize.js";

export const CUSTOM_JSON_MAX_BYTES = 64 * 1024;

export interface CustomJsonSummary {
  name: string;
  status: "ok" | "degraded";
  message: string;
  observed_at: string;
  tags: string[];
  safe_values?: unknown;
}

export async function collectCustomJsonFiles(files: CustomJsonFileConfig[] | undefined, capturedAt: string): Promise<Record<string, unknown>> {
  const configured = files ?? [];
  return {
    files_count: configured.length,
    files: await Promise.all(configured.map((file) => collectCustomJsonFile(file, capturedAt)))
  };
}

export async function collectCustomJsonFile(file: CustomJsonFileConfig, capturedAt: string): Promise<CustomJsonSummary> {
  try {
    const info = await stat(file.path);
    if (info.size > CUSTOM_JSON_MAX_BYTES) {
      return errorSummary(file.name, capturedAt, "custom json file exceeds size limit");
    }
    const parsed = JSON.parse(await readFile(file.path, "utf8")) as unknown;
    return normalizeCustomJson(file.name, parsed, capturedAt);
  } catch {
    return errorSummary(file.name, capturedAt, "custom json file unavailable or invalid");
  }
}

export function normalizeCustomJson(name: string, value: unknown, capturedAt: string): CustomJsonSummary {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return errorSummary(name, capturedAt, "custom json root must be an object");
  }
  const record = value as Record<string, unknown>;
  const safeDeclared = record.safe === true;
  const status = safeStatus(record.status);
  const summary: CustomJsonSummary = {
    name: safeString(name),
    status,
    message: safeString(stringValue(record.message) ?? (safeDeclared ? "custom json accepted" : "custom json summarized")),
    observed_at: safeString(stringValue(record.observed_at) ?? capturedAt),
    tags: sanitizeTags(record.tags)
  };

  if (safeDeclared) {
    const safeValues = sanitizeSafeValues(record.safe_values ?? record.data ?? {});
    if (safeValues !== undefined) summary.safe_values = safeValues;
  }
  return summary;
}

function errorSummary(name: string, capturedAt: string, message: string): CustomJsonSummary {
  return {
    name: safeString(name),
    status: "degraded",
    message,
    observed_at: capturedAt,
    tags: []
  };
}

function sanitizeSafeValues(value: unknown): unknown {
  if (typeof value === "string") return safeString(value);
  if (Array.isArray(value)) return value.map(sanitizeSafeValues);
  if (!value || typeof value !== "object") return value;

  const output: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    if (isForbiddenKey(key)) continue;
    output[key] = sanitizeSafeValues(item);
  }
  return output;
}

function sanitizeTags(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === "string").map(safeString).filter((item) => item.length > 0).slice(0, 20);
}

function safeStatus(value: unknown): "ok" | "degraded" {
  return value === "ok" || value === "healthy" ? "ok" : value === "degraded" || value === "down" || value === "error" ? "degraded" : "ok";
}

function safeString(value: string): string {
  const sanitized = sanitizeTelemetryString(value);
  return findForbiddenTelemetryMarkers(sanitized).length > 0 ? "[redacted]" : sanitized.slice(0, 200);
}

function isForbiddenKey(key: string): boolean {
  return /^(raw|env|logs?|headers?|authorization|cookies?|access_token|refresh_token|id_token|account_id|user_id|email|secret|password)$/i.test(key) ||
    findForbiddenTelemetryMarkers(key).length > 0;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
