import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { findForbiddenTelemetryMarkers } from "../../telemetry/forbiddenMarkers.js";
import { sanitizeTelemetryString } from "../../telemetry/sanitize.js";
import type { ServerStatus } from "../serverTypes.js";

const execFileAsync = promisify(execFile);

export interface SystemdUnitSummary {
  name: string;
  active_state: string;
  sub_state: string;
  load_state: string;
  since: string | null;
  description: string | null;
  status: ServerStatus;
}

export async function collectSystemdUnits(units: string[]): Promise<Record<string, unknown>> {
  const summaries: SystemdUnitSummary[] = [];
  let unavailable = false;
  for (const unit of units) {
    try {
      const { stdout } = await execFileAsync(
        "systemctl",
        ["show", unit, "--property=Id,Description,LoadState,ActiveState,SubState,ActiveEnterTimestamp", "--no-pager"],
        { timeout: 5000, windowsHide: true }
      );
      summaries.push(parseSystemctlShow(stdout, unit));
    } catch {
      unavailable = true;
      summaries.push({
        name: safeUnitName(unit),
        active_state: "unknown",
        sub_state: "unknown",
        load_state: "unknown",
        since: null,
        description: null,
        status: "unknown"
      });
    }
  }

  return {
    status: unavailable ? "degraded" : "ok",
    units_count: summaries.length,
    units: summaries,
    ...(unavailable ? { message: "systemd unavailable or unit query failed" } : {})
  };
}

export function parseSystemctlShow(text: string, fallbackName: string): SystemdUnitSummary {
  const fields = new Map<string, string>();
  for (const line of text.split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index <= 0) continue;
    fields.set(line.slice(0, index), line.slice(index + 1));
  }
  const active = safeString(fields.get("ActiveState") || "unknown");
  const sub = safeString(fields.get("SubState") || "unknown");
  const load = safeString(fields.get("LoadState") || "unknown");

  return {
    name: safeUnitName(fields.get("Id") || fallbackName),
    active_state: active,
    sub_state: sub,
    load_state: load,
    since: safeTimestamp(fields.get("ActiveEnterTimestamp")),
    description: safeDescription(fields.get("Description")),
    status: unitStatus(active, sub, load)
  };
}

function unitStatus(active: string, sub: string, load: string): ServerStatus {
  if (load === "not-found") return "down";
  if (active === "active" && (sub === "running" || sub === "exited")) return "healthy";
  if (active === "failed" || active === "inactive") return "down";
  if (active === "unknown" || load === "unknown") return "unknown";
  return "degraded";
}

function safeTimestamp(value: string | undefined): string | null {
  if (!value || value === "n/a") return null;
  return safeString(value).slice(0, 80);
}

function safeDescription(value: string | undefined): string | null {
  if (!value) return null;
  return safeString(value).slice(0, 120);
}

function safeUnitName(value: string): string {
  return /^[A-Za-z0-9_.@:-]+$/.test(value) ? value : "redacted-unit";
}

function safeString(value: string): string {
  const sanitized = sanitizeTelemetryString(value);
  return findForbiddenTelemetryMarkers(sanitized).length > 0 ? "[redacted]" : sanitized;
}
