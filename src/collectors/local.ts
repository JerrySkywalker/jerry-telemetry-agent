import { execFile } from "node:child_process";
import { readFile, stat } from "node:fs/promises";
import os from "node:os";
import { promisify } from "node:util";
import packageJson from "../../package.json" with { type: "json" };
import { findForbiddenTelemetryMarkers } from "../telemetry/forbiddenMarkers.js";
import { sanitizeTelemetryString } from "../telemetry/sanitize.js";

const execFileAsync = promisify(execFile);
const CUSTOM_JSON_LIMIT_BYTES = 64 * 1024;

export type LocalCollectionMode = "Fixture" | "LocalWindows";

export interface LocalCollectorContext {
  mode: LocalCollectionMode;
  nodeId: string;
  hostname: string;
  region: string;
  role: string;
  provider: string;
  capturedAt: string;
  customJsonFile?: string;
  serviceHealthFile?: string;
}

export interface DiskSummary {
  drive?: string;
  mount?: string;
  name?: string;
  total_bytes: number | null;
  free_bytes: number | null;
  used_percent: number | null;
}

export interface ServiceHealthItem {
  name: string;
  kind: string;
  status: string;
  last_check: string;
  message: string;
  response_time_ms?: number | null;
  port?: number | null;
}

export function collectNodeInfo(context: LocalCollectorContext): Record<string, unknown> {
  if (context.mode === "Fixture") {
    return {
      node_id: context.nodeId,
      hostname: context.hostname,
      region: context.region,
      role: context.role,
      provider: context.provider,
      platform: "fixture",
      os: "fixture-os",
      kernel: "fixture-kernel",
      arch: "x64",
      uptime_seconds: 12345,
      agent_version: packageJson.version
    };
  }

  return {
    node_id: context.nodeId,
    hostname: context.hostname,
    region: context.region,
    role: context.role,
    provider: context.provider,
    platform: process.platform,
    os: `${os.type()} ${os.release()}`.trim(),
    kernel: os.release(),
    arch: os.arch(),
    uptime_seconds: Math.max(0, Math.floor(os.uptime())),
    agent_version: packageJson.version
  };
}

export async function collectNodeResources(context: LocalCollectorContext): Promise<Record<string, unknown>> {
  if (context.mode === "Fixture") {
    return {
      cpu_percent: null,
      memory_percent: 25,
      memory_total_bytes: 8 * 1024 * 1024 * 1024,
      memory_free_bytes: 6 * 1024 * 1024 * 1024,
      load_1m: null,
      load_5m: null,
      load_15m: null,
      uptime_seconds: 12345,
      process_count: null,
      disks: [
        {
          drive: "fixture-disk",
          total_bytes: 128 * 1024 * 1024 * 1024,
          free_bytes: 96 * 1024 * 1024 * 1024,
          used_percent: 25
        }
      ]
    };
  }

  const totalMemory = os.totalmem();
  const freeMemory = os.freemem();
  const load = process.platform === "win32" ? [null, null, null] : os.loadavg().map((item) => roundNumber(item));

  return {
    cpu_percent: null,
    memory_percent: totalMemory > 0 ? roundNumber(((totalMemory - freeMemory) / totalMemory) * 100) : null,
    memory_total_bytes: totalMemory || null,
    memory_free_bytes: freeMemory || null,
    load_1m: load[0],
    load_5m: load[1],
    load_15m: load[2],
    uptime_seconds: Math.max(0, Math.floor(os.uptime())),
    process_count: null,
    disks: await collectDiskSummaries()
  };
}

export async function collectServiceHealth(context: LocalCollectorContext): Promise<Record<string, unknown>> {
  if (context.serviceHealthFile) {
    const parsed = await readJsonFileLimited(context.serviceHealthFile);
    const rawServices: unknown[] = Array.isArray(parsed)
      ? parsed
      : parsed && typeof parsed === "object" && Array.isArray((parsed as Record<string, unknown>).services)
        ? (parsed as { services: unknown[] }).services
        : [];
    return { services: rawServices.map((item) => normalizeService(item, context.capturedAt)).filter((item): item is ServiceHealthItem => Boolean(item)) };
  }

  return {
    services: [
      {
        name: "fixture-local-service",
        kind: "fixture",
        status: "ok",
        last_check: context.capturedAt,
        message: "fixture healthy",
        response_time_ms: null,
        port: null
      }
    ]
  };
}

export async function collectCustomJson(context: LocalCollectorContext): Promise<Record<string, unknown>> {
  if (!context.customJsonFile) {
    return {
      source: "fixture",
      safe_declared: true,
      data: {
        label: "synthetic-custom-sample",
        status: "ok",
        value: 42
      }
    };
  }

  const info = await stat(context.customJsonFile);
  if (info.size > CUSTOM_JSON_LIMIT_BYTES) {
    throw new Error(`Custom JSON fixture exceeds ${CUSTOM_JSON_LIMIT_BYTES} byte limit`);
  }

  const parsed = await readJsonFileLimited(context.customJsonFile);
  const safeDeclared = isSafeDeclaredCustomJson(parsed);
  const data = safeDeclared ? sanitizeCustomJson((parsed as Record<string, unknown>).data) : undefined;
  return {
    source: "file",
    safe_declared: safeDeclared,
    summary: summarizeJson(parsed, info.size),
    ...(data === undefined ? {} : { data })
  };
}

async function collectDiskSummaries(): Promise<DiskSummary[]> {
  if (process.platform === "win32") return collectWindowsDiskSummaries();
  return collectUnixRootDiskSummary();
}

async function collectWindowsDiskSummaries(): Promise<DiskSummary[]> {
  const script = "Get-CimInstance Win32_LogicalDisk -Filter \"DriveType=3\" | Select-Object DeviceID,VolumeName,Size,FreeSpace | ConvertTo-Json -Compress";
  try {
    const { stdout } = await execFileAsync("powershell", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script], {
      timeout: 5000,
      windowsHide: true
    });
    const parsed = JSON.parse(stdout.trim() || "[]") as unknown;
    const items = Array.isArray(parsed) ? parsed : [parsed];
    return items.map(normalizeWindowsDisk).filter((item): item is DiskSummary => Boolean(item));
  } catch {
    return [];
  }
}

async function collectUnixRootDiskSummary(): Promise<DiskSummary[]> {
  try {
    const { stdout } = await execFileAsync("df", ["-P", "-B1", "/"], { timeout: 5000, windowsHide: true });
    const [, line] = stdout.trim().split(/\r?\n/);
    if (!line) return [];
    const parts = line.trim().split(/\s+/);
    const total = safeNumber(parts[1]);
    const used = safeNumber(parts[2]);
    const free = safeNumber(parts[3]);
    return [
      {
        mount: parts[5] || "/",
        name: "root",
        total_bytes: total,
        free_bytes: free,
        used_percent: total && used !== null ? roundNumber((used / total) * 100) : null
      }
    ];
  } catch {
    return [];
  }
}

function normalizeWindowsDisk(value: unknown): DiskSummary | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  const total = numberValue(record.Size);
  const free = numberValue(record.FreeSpace);
  return {
    drive: stringValue(record.DeviceID) ?? "unknown",
    name: sanitizeSafeString(stringValue(record.VolumeName) ?? "local-disk"),
    total_bytes: total,
    free_bytes: free,
    used_percent: total && free !== null ? roundNumber(((total - free) / total) * 100) : null
  };
}

function normalizeService(value: unknown, capturedAt: string): ServiceHealthItem | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  return {
    name: sanitizeSafeString(stringValue(record.name) ?? "service"),
    kind: sanitizeSafeString(stringValue(record.kind) ?? "fixture"),
    status: sanitizeSafeString(stringValue(record.status) ?? "unknown"),
    last_check: sanitizeSafeString(stringValue(record.last_check) ?? capturedAt),
    message: sanitizeSafeString(stringValue(record.message) ?? "not reported"),
    response_time_ms: numberValue(record.response_time_ms),
    port: normalizePort(record.port)
  };
}

async function readJsonFileLimited(file: string): Promise<unknown> {
  const info = await stat(file);
  if (info.size > CUSTOM_JSON_LIMIT_BYTES) {
    throw new Error(`JSON fixture exceeds ${CUSTOM_JSON_LIMIT_BYTES} byte limit`);
  }
  return JSON.parse(await readFile(file, "utf8")) as unknown;
}

function isSafeDeclaredCustomJson(value: unknown): value is { safe: true; data: unknown } {
  return Boolean(value && typeof value === "object" && !Array.isArray(value) && (value as Record<string, unknown>).safe === true && "data" in value);
}

function summarizeJson(value: unknown, sizeBytes: number): Record<string, unknown> {
  if (Array.isArray(value)) return { top_level_type: "array", array_length: value.length, size_bytes: sizeBytes };
  if (value && typeof value === "object") return { top_level_type: "object", object_key_count: Object.keys(value).length, size_bytes: sizeBytes };
  return { top_level_type: typeof value, size_bytes: sizeBytes };
}

function sanitizeCustomJson(value: unknown): unknown {
  if (typeof value === "string") return sanitizeSafeString(value);
  if (Array.isArray(value)) return value.map(sanitizeCustomJson);
  if (!value || typeof value !== "object") return value;

  const output: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    if (findForbiddenTelemetryMarkers(key).length > 0) continue;
    output[key] = sanitizeCustomJson(item);
  }
  return output;
}

function sanitizeSafeString(value: string): string {
  const sanitized = sanitizeTelemetryString(value);
  return findForbiddenTelemetryMarkers(sanitized).length > 0 ? "[redacted]" : sanitized;
}

function normalizePort(value: unknown): number | null {
  const port = numberValue(value);
  return port !== null && Number.isInteger(port) && port > 0 && port <= 65535 ? port : null;
}

function roundNumber(value: number): number {
  return Math.round(value * 10) / 10;
}

function safeNumber(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
