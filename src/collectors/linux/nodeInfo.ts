import { readFile } from "node:fs/promises";
import os from "node:os";
import packageJson from "../../../package.json" with { type: "json" };
import type { ServerCollectorContext } from "../serverTypes.js";
import { sanitizeTelemetryString } from "../../telemetry/sanitize.js";

export interface LinuxNodeInfoDeps {
  platform?: NodeJS.Platform;
  osReleaseText?: string;
}

export async function collectLinuxNodeInfo(context: ServerCollectorContext, deps: LinuxNodeInfoDeps = {}): Promise<Record<string, unknown>> {
  const platform = deps.platform ?? process.platform;
  const osRelease = deps.osReleaseText ?? (platform === "linux" ? await readOsRelease() : undefined);
  const osName = osRelease ? parseOsReleaseName(osRelease) : `${os.type()} ${os.release()}`.trim();

  return {
    node_id: context.nodeId,
    hostname: context.hostname,
    region: context.region,
    role: context.role,
    provider: context.provider,
    platform,
    os: sanitizeTelemetryString(osName),
    kernel: sanitizeTelemetryString(os.release()),
    arch: os.arch(),
    uptime_seconds: Math.max(0, Math.floor(os.uptime())),
    agent_version: packageJson.version
  };
}

export function parseOsReleaseName(text: string): string {
  const fields = new Map<string, string>();
  for (const line of text.split(/\r?\n/)) {
    const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (!match) continue;
    fields.set(match[1], unquoteOsReleaseValue(match[2]));
  }
  return fields.get("PRETTY_NAME") ?? ([fields.get("NAME"), fields.get("VERSION_ID")].filter(Boolean).join(" ") || "linux");
}

async function readOsRelease(): Promise<string | undefined> {
  try {
    return await readFile("/etc/os-release", "utf8");
  } catch {
    return undefined;
  }
}

function unquoteOsReleaseValue(value: string): string {
  const trimmed = value.trim();
  if (trimmed.startsWith("\"") && trimmed.endsWith("\"")) {
    return trimmed.slice(1, -1).replace(/\\"/g, "\"");
  }
  return trimmed;
}
