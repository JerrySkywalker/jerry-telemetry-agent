import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { findForbiddenTelemetryMarkers } from "../../telemetry/forbiddenMarkers.js";
import { sanitizeTelemetryString } from "../../telemetry/sanitize.js";

const execFileAsync = promisify(execFile);

export interface DockerContainerSummary {
  name: string;
  image: string;
  status: string;
  state: string;
  health: string | null;
  restart_count: number | null;
  started_at: string | null;
  ports: DockerPortSummary[];
}

export interface DockerPortSummary {
  host_port: number | null;
  container_port: number | null;
  protocol: string | null;
}

export async function collectDockerContainers(allowlist: string[] | undefined): Promise<Record<string, unknown>> {
  try {
    const { stdout } = await execFileAsync("docker", ["ps", "--all", "--format", "{{json .}}"], { timeout: 5000, windowsHide: true });
    const containers = parseDockerPsJsonLines(stdout, allowlist);
    return {
      status: "ok",
      containers_count: containers.length,
      containers
    };
  } catch {
    return {
      status: "unknown",
      containers_count: 0,
      containers: [],
      message: "docker unavailable"
    };
  }
}

export function parseDockerPsJsonLines(text: string, allowlist: string[] | undefined): DockerContainerSummary[] {
  const containers: DockerContainerSummary[] = [];
  for (const line of text.split(/\r?\n/).map((item) => item.trim()).filter(Boolean)) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(line) as unknown;
    } catch {
      continue;
    }
    const record = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : undefined;
    if (!record) continue;
    const name = safeString(stringValue(record.Names) ?? stringValue(record.Name) ?? "container");
    if (!isAllowed(name, allowlist)) continue;
    containers.push({
      name,
      image: safeImage(stringValue(record.Image) ?? "unknown"),
      status: safeString(stringValue(record.Status) ?? "unknown"),
      state: safeString(stringValue(record.State) ?? "unknown"),
      health: parseHealth(stringValue(record.Status)),
      restart_count: numberValue(record.RestartCount),
      started_at: stringValue(record.CreatedAt) ? safeString(String(record.CreatedAt)) : null,
      ports: parsePorts(stringValue(record.Ports) ?? "")
    });
  }
  return containers;
}

export function parsePorts(value: string): DockerPortSummary[] {
  const ports: DockerPortSummary[] = [];
  for (const part of value.split(",").map((item) => item.trim()).filter(Boolean)) {
    const match = /(?:(?::|\[::\]:|0\.0\.0\.0:)(\d+)->)?(\d+)\/([a-z0-9]+)/i.exec(part);
    if (!match) continue;
    ports.push({
      host_port: match[1] ? Number.parseInt(match[1], 10) : null,
      container_port: Number.parseInt(match[2], 10),
      protocol: match[3].toLowerCase()
    });
  }
  return ports;
}

function isAllowed(name: string, allowlist: string[] | undefined): boolean {
  if (!allowlist || allowlist.length === 0) return true;
  return allowlist.some((pattern) => wildcardMatch(name, pattern));
}

function wildcardMatch(value: string, pattern: string): boolean {
  const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp(`^${escaped}$`).test(value);
}

function parseHealth(status: string | undefined): string | null {
  if (!status) return null;
  const match = /\((healthy|unhealthy|starting)\)/i.exec(status);
  return match ? match[1].toLowerCase() : null;
}

function safeImage(value: string): string {
  return safeString(value.length > 160 ? value.slice(0, 160) : value);
}

function safeString(value: string): string {
  const sanitized = sanitizeTelemetryString(value);
  return findForbiddenTelemetryMarkers(sanitized).length > 0 ? "[redacted]" : sanitized;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
