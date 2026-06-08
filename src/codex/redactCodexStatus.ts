const SENSITIVE_KEY_PATTERN = /(account|session)([_-]?id)?$/i;
const REDACTED = "[REDACTED]";

export function redactCodexStatus(input: unknown): Record<string, unknown> {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("Codex status payload must be an object");
  }
  return redactObject(input as Record<string, unknown>) as Record<string, unknown>;
}

function redactObject(input: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(input)) {
    if (SENSITIVE_KEY_PATTERN.test(key)) {
      result[key] = REDACTED;
    } else if (Array.isArray(value)) {
      result[key] = value.map((item) => {
        if (item && typeof item === "object") return redactObject(item as Record<string, unknown>);
        return item;
      });
    } else if (value && typeof value === "object") {
      result[key] = redactObject(value as Record<string, unknown>);
    } else {
      result[key] = value;
    }
  }
  return result;
}
