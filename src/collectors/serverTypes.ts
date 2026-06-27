export interface ServerCollectorContext {
  nodeId: string;
  hostname: string;
  region: string;
  role: string;
  provider: string;
  capturedAt: string;
}

export type ServerStatus = "healthy" | "degraded" | "down" | "unknown";

export interface SafeCollectorError {
  ok: false;
  error_code: string;
  message: string;
}

export function collectorErrorPayload(errorCode: string, message = "collector unavailable"): SafeCollectorError {
  return {
    ok: false,
    error_code: errorCode,
    message
  };
}
