export const FORBIDDEN_TELEMETRY_MARKERS = [
  "TELEMETRY_NODE_SECRET=",
  "TELEMETRY_READ_TOKEN=",
  "Authorization: Bearer ",
  "Authorization:",
  "Cookie:",
  "Set-Cookie:",
  "access_token",
  "refresh_token",
  "id_token",
  "auth.json",
  "account_id",
  "user_id",
  "email",
  "raw_response",
  "BEGIN OPENSSH PRIVATE KEY"
] as const;

export function findForbiddenTelemetryMarkers(value: unknown): string[] {
  const serialized = typeof value === "string" ? value : JSON.stringify(value);
  const haystack = serialized.toLowerCase();
  return FORBIDDEN_TELEMETRY_MARKERS.filter((marker) => haystack.includes(marker.toLowerCase()));
}

export function assertNoForbiddenTelemetryMarkers(value: unknown): void {
  const found = findForbiddenTelemetryMarkers(value);
  if (found.length > 0) {
    throw new Error("Telemetry payload contains a forbidden marker");
  }
}
