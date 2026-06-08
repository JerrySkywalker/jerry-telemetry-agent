const REDACTED_VALUES = new Set(["[REDACTED]", "redacted", null]);
const SENSITIVE_KEY_PATTERN = /(account|session)([_-]?id)?$/i;

export function validateCodexLatest(payload: Record<string, unknown>): void {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("Codex latest payload must be an object");
  }
  const capturedAt = payload.captured_at;
  if (typeof capturedAt !== "string" || Number.isNaN(Date.parse(capturedAt))) {
    throw new Error("Codex latest payload requires valid captured_at");
  }
  if (typeof payload.status !== "string" || payload.status.length === 0) {
    throw new Error("Codex latest payload requires status");
  }
  assertSensitiveRedacted(payload);
}

function assertSensitiveRedacted(value: unknown, path = "$"): void {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertSensitiveRedacted(item, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    const nextPath = `${path}.${key}`;
    if (SENSITIVE_KEY_PATTERN.test(key) && !REDACTED_VALUES.has(item as never)) {
      throw new Error(`Codex payload contains unredacted sensitive field: ${nextPath}`);
    }
    assertSensitiveRedacted(item, nextPath);
  }
}
