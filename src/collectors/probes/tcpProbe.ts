import net from "node:net";
import type { TcpProbeTarget } from "../registry.js";
import type { ServerStatus } from "../serverTypes.js";
import { findForbiddenTelemetryMarkers } from "../../telemetry/forbiddenMarkers.js";
import { sanitizeTelemetryString } from "../../telemetry/sanitize.js";

export interface TcpProbeResult {
  name: string;
  kind: "tcp";
  status: ServerStatus;
  last_check: string;
  response_time_ms: number | null;
  port: number;
  message: string;
}

export async function collectTcpProbes(targets: TcpProbeTarget[], capturedAt: string): Promise<Record<string, unknown>> {
  return {
    services: await Promise.all(targets.map((target) => runTcpProbe(target, capturedAt)))
  };
}

export function runTcpProbe(target: TcpProbeTarget, capturedAt: string): Promise<TcpProbeResult> {
  if (!Number.isInteger(target.port) || target.port < 1 || target.port > 65535) {
    throw new Error("TCP probe port must be an integer from 1 to 65535");
  }

  const started = Date.now();
  const timeoutMs = target.timeout_ms ?? 1000;
  return new Promise((resolve) => {
    const socket = net.createConnection({ host: target.host, port: target.port });
    let resolved = false;
    const finish = (status: ServerStatus, message: string) => {
      if (resolved) return;
      resolved = true;
      socket.destroy();
      resolve({
        name: safeName(target.name),
        kind: "tcp",
        status,
        last_check: capturedAt,
        response_time_ms: Date.now() - started,
        port: target.port,
        message
      });
    };

    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finish("healthy", "tcp probe connected"));
    socket.once("timeout", () => finish("down", "tcp probe timed out"));
    socket.once("error", () => finish("down", "tcp probe failed"));
  });
}

function safeName(value: string): string {
  const sanitized = sanitizeTelemetryString(value);
  return findForbiddenTelemetryMarkers(sanitized).length > 0 ? "redacted-target" : sanitized;
}
