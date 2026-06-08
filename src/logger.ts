const SECRET_KEY_PATTERN = /(secret|token|authorization|password|api[_-]?key)/i;

export type LogLevel = "debug" | "info" | "warn" | "error";

function sanitizeValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sanitizeValue);
  if (value && typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value)) {
      result[key] = SECRET_KEY_PATTERN.test(key) ? "[REDACTED]" : sanitizeValue(item);
    }
    return result;
  }
  return value;
}

function write(level: LogLevel, message: string, meta?: unknown): void {
  const entry = {
    level,
    message,
    time: new Date().toISOString(),
    ...(meta === undefined ? {} : { meta: sanitizeValue(meta) })
  };
  const line = JSON.stringify(entry);
  if (level === "error") console.error(line);
  else console.log(line);
}

export const logger = {
  debug: (message: string, meta?: unknown) => write("debug", message, meta),
  info: (message: string, meta?: unknown) => write("info", message, meta),
  warn: (message: string, meta?: unknown) => write("warn", message, meta),
  error: (message: string, meta?: unknown) => write("error", message, meta)
};
