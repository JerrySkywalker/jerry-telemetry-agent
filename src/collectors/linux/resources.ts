import { execFile } from "node:child_process";
import { readdir } from "node:fs/promises";
import os from "node:os";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface LinuxResourceDeps {
  platform?: NodeJS.Platform;
  dfOutput?: string;
}

export interface LinuxDiskSummary {
  mount: string;
  filesystem_type?: string;
  total_bytes: number | null;
  free_bytes: number | null;
  used_percent: number | null;
}

export async function collectLinuxResources(deps: LinuxResourceDeps = {}): Promise<Record<string, unknown>> {
  const platform = deps.platform ?? process.platform;
  const totalMemory = os.totalmem();
  const freeMemory = os.freemem();
  const load = platform === "win32" ? [null, null, null] : os.loadavg().map((value) => roundNumber(value));

  return {
    cpu_percent: null,
    memory_percent: totalMemory > 0 ? roundNumber(((totalMemory - freeMemory) / totalMemory) * 100) : null,
    memory_total_bytes: totalMemory || null,
    memory_free_bytes: freeMemory || null,
    load_1m: load[0],
    load_5m: load[1],
    load_15m: load[2],
    uptime_seconds: Math.max(0, Math.floor(os.uptime())),
    process_count: platform === "linux" ? await countLinuxProcesses() : null,
    disks: await collectLinuxDisks(platform, deps.dfOutput),
    network: summarizeNetworkStatus()
  };
}

export function parseDfOutput(text: string): LinuxDiskSummary[] {
  const lines = text.trim().split(/\r?\n/).slice(1);
  const disks: LinuxDiskSummary[] = [];
  for (const line of lines) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 7) continue;
    const total = safeInteger(parts[2]);
    const used = safeInteger(parts[3]);
    const free = safeInteger(parts[4]);
    disks.push({
      filesystem_type: safeFilesystemType(parts[1]),
      mount: safeMount(parts.slice(6).join(" ")),
      total_bytes: total,
      free_bytes: free,
      used_percent: total && used !== null ? roundNumber((used / total) * 100) : null
    });
  }
  return disks;
}

async function collectLinuxDisks(platform: NodeJS.Platform, dfOutput?: string): Promise<LinuxDiskSummary[]> {
  if (dfOutput !== undefined) return parseDfOutput(dfOutput);
  if (platform !== "linux") return [];
  try {
    const { stdout } = await execFileAsync("df", ["-PT", "-B1", "/"], { timeout: 5000, windowsHide: true });
    return parseDfOutput(stdout);
  } catch {
    return [];
  }
}

async function countLinuxProcesses(): Promise<number | null> {
  try {
    const entries = await readdir("/proc", { withFileTypes: true });
    return entries.filter((entry) => entry.isDirectory() && /^\d+$/.test(entry.name)).length;
  } catch {
    return null;
  }
}

function summarizeNetworkStatus(): Record<string, unknown> {
  const interfaces = os.networkInterfaces();
  let activeInterfaceCount = 0;
  for (const addresses of Object.values(interfaces)) {
    if (addresses?.some((item) => !item.internal)) activeInterfaceCount += 1;
  }
  return {
    status: activeInterfaceCount > 0 ? "ok" : "unknown",
    active_interface_count: activeInterfaceCount
  };
}

function safeInteger(value: string | undefined): number | null {
  if (!value) return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function safeMount(value: string): string {
  if (!value || value.startsWith("/home/")) return "redacted-mount";
  return value.length > 80 ? value.slice(0, 80) : value;
}

function safeFilesystemType(value: string | undefined): string | undefined {
  if (!value || !/^[A-Za-z0-9_.-]+$/.test(value)) return undefined;
  return value;
}

function roundNumber(value: number): number {
  return Math.round(value * 10) / 10;
}
