export interface RedactedShapeField {
  path: string;
  present: boolean;
  type: "number" | "string" | "boolean" | "array" | "object" | "null" | "missing";
  array_count?: number;
}

const LIMIT_FIELD_CANDIDATES = [
  "total",
  "limit",
  "quota",
  "cap",
  "max",
  "amount",
  "credits_total",
  "used",
  "consumed",
  "spent",
  "credits_used",
  "remaining",
  "available",
  "left",
  "credits_remaining",
  "used_percent",
  "percent_used",
  "usage_percent",
  "remaining_percent",
  "percent_remaining",
  "reset_at",
  "resetAt",
  "reset_time",
  "resetTime",
  "reset_at_iso",
  "resets_at",
  "reset_in_seconds",
  "reset_after_seconds",
  "seconds_until_reset",
  "window_seconds",
  "period_seconds",
  "interval_seconds",
  "quota_window_seconds",
  "limit_window_seconds",
  "name",
  "label",
  "display_name",
  "limit_name",
  "metered_feature",
  "model",
  "model_slug",
  "unit",
  "group_label",
  "window_label",
  "window",
  "period",
  "interval",
  "primary_window",
  "secondary_window",
  "rate_limit"
] as const;

export function inspectCodexUsageShape(raw: unknown): RedactedShapeField[] {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return [{ path: "payload", present: false, type: shapeType(raw) }];
  }

  const record = raw as Record<string, unknown>;
  const fields: RedactedShapeField[] = [];
  fields.push(field("payload.rate_limit", record.rate_limit));
  fields.push(field("payload.additional_rate_limits", record.additional_rate_limits));

  const limitSamples = collectLimitSamples(record);
  fields.push({
    path: "payload.limits[]",
    present: limitSamples.length > 0,
    type: limitSamples.length > 0 ? "object" : "missing",
    array_count: limitSamples.length
  });

  for (const name of LIMIT_FIELD_CANDIDATES) {
    const value = firstPresent(limitSamples, name);
    fields.push(field(`payload.limits[].${name}`, value, limitSamples.length > 0));
  }

  return fields;
}

function collectLimitSamples(record: Record<string, unknown>): Record<string, unknown>[] {
  const samples: Record<string, unknown>[] = [];
  if (record.rate_limit && typeof record.rate_limit === "object" && !Array.isArray(record.rate_limit)) {
    collectLimitSamplesFromRecord(record.rate_limit as Record<string, unknown>, samples);
  }
  if (Array.isArray(record.additional_rate_limits)) {
    for (const item of record.additional_rate_limits) {
      if (item && typeof item === "object" && !Array.isArray(item)) collectLimitSamplesFromRecord(item as Record<string, unknown>, samples);
    }
  }
  if (Array.isArray(record.limits)) {
    for (const item of record.limits) {
      if (item && typeof item === "object" && !Array.isArray(item)) collectLimitSamplesFromRecord(item as Record<string, unknown>, samples);
    }
  }
  return samples;
}

function collectLimitSamplesFromRecord(record: Record<string, unknown>, samples: Record<string, unknown>[]): void {
  samples.push(record);
  const nested = record.rate_limit;
  if (nested && typeof nested === "object" && !Array.isArray(nested)) {
    collectLimitSamplesFromRecord(nested as Record<string, unknown>, samples);
  }
  for (const key of ["primary_window", "secondary_window"] as const) {
    const value = record[key];
    if (value && typeof value === "object" && !Array.isArray(value)) samples.push(value as Record<string, unknown>);
  }
}

function firstPresent(records: Record<string, unknown>[], key: string): unknown {
  for (const record of records) {
    if (record[key] !== undefined) return record[key];
  }
  return undefined;
}

function field(path: string, value: unknown, parentPresent = true): RedactedShapeField {
  const present = parentPresent && value !== undefined;
  return {
    path,
    present,
    type: present ? shapeType(value) : "missing",
    array_count: Array.isArray(value) ? value.length : undefined
  };
}

function shapeType(value: unknown): RedactedShapeField["type"] {
  if (value === undefined) return "missing";
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "number") return "number";
  if (typeof value === "string") return "string";
  if (typeof value === "boolean") return "boolean";
  if (typeof value === "object") return "object";
  return "missing";
}
