const OMIT_KEYS = new Set([
  "access_token",
  "refresh_token",
  "id_token",
  "authorization",
  "authorization_header",
  "bearer",
  "cookie",
  "cookies",
  "set-cookie",
  "telemetry_node_secret",
  "telemetry_read_token",
  "env",
  ".env",
  "auth_json",
  "raw_response",
  "raw_logs",
  "account_id",
  "user_id",
  "email",
  "referral_beacon",
  "promo"
]);

const AUTH_FILE_PATH_PATTERN = /(?:[A-Za-z]:)?(?:[/\\][^"'`\s<>:|?*]+)*[/\\]\.codex[/\\]auth\.json/gi;
const BEARER_PATTERN = /\bBearer\s+[A-Za-z0-9._~+/=-]+/gi;
const AUTHORIZATION_PATTERN = /\bAuthorization\s*[:=]\s*[^\s,;]+(?:\s+[^\s,;]+)?/gi;

export function sanitizeTelemetryString(value: string): string {
  return value
    .replace(AUTH_FILE_PATH_PATTERN, "<auth_file>")
    .replace(BEARER_PATTERN, "Bearer <redacted>")
    .replace(AUTHORIZATION_PATTERN, "Authorization: <redacted>")
    .replace(/auth\.json/gi, "auth_file");
}

export function sanitizeErrorForTelemetry(error: unknown, fallbackCode = "agent_iteration_error"): { error_code: string; message: string } {
  const code = typeof (error as { code?: unknown })?.code === "string" ? String((error as { code: string }).code) : fallbackCode;
  return {
    error_code: sanitizeTelemetryString(code),
    message: sanitizeTelemetryString((error as Error)?.message ?? "telemetry error")
  };
}

export function sanitizeSnapshotPayload<T>(value: T): T {
  return sanitizeValue(value) as T;
}

function sanitizeValue(value: unknown): unknown {
  if (typeof value === "string") return sanitizeTelemetryString(value);
  if (Array.isArray(value)) return value.map(sanitizeValue);
  if (!value || typeof value !== "object") return value;

  const output: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    const lowerKey = key.toLowerCase();
    if (OMIT_KEYS.has(lowerKey)) continue;
    output[key] = sanitizeValue(item);
  }
  return output;
}
