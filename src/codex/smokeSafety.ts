const tokenMarker = (prefix: string) => `${prefix}_token`;

export const SMOKE_FORBIDDEN_STRINGS = [
  tokenMarker("access"),
  tokenMarker("refresh"),
  "email",
  "account_id",
  "user_id",
  "id_token",
  "referral_beacon",
  "promo"
] as const;

export interface SmokeValidationResult {
  ok: boolean;
  errors: string[];
}

export function validateCodexUsageSmokeSnapshot(snapshot: unknown): SmokeValidationResult {
  const errors: string[] = [];
  const serialized = JSON.stringify(snapshot);

  for (const marker of SMOKE_FORBIDDEN_STRINGS) {
    if (serialized.includes(marker)) {
      errors.push(`snapshot contains forbidden marker: ${marker}`);
    }
  }

  if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) {
    return { ok: false, errors: ["snapshot is not an object", ...errors] };
  }

  const record = snapshot as Record<string, unknown>;
  if (record.type !== "codex.usage.snapshot") errors.push("type is not codex.usage.snapshot");
  if (!record.status || typeof record.status !== "object") {
    errors.push("status is missing");
  } else if (typeof (record.status as Record<string, unknown>).ok !== "boolean") {
    errors.push("status.ok is missing");
  }
  if (!Array.isArray(record.limits)) errors.push("limits is not an array");
  if (!Array.isArray(record.limits_detail)) errors.push("limits_detail is not an array");
  if (typeof record.observed_at !== "string" || record.observed_at.length === 0) errors.push("observed_at is missing");

  const node = record.node;
  if (!node || typeof node !== "object" || typeof (node as Record<string, unknown>).id !== "string") {
    errors.push("node.id is missing");
  }

  if (Array.isArray(record.limits)) {
    const limits = record.limits.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object" && !Array.isArray(item));
    const hasDefault = limits.some((limit) => limit.scope === "default" || limit.name === "default");
    if (limits.length > 0 && !hasDefault) errors.push("limits are present but no default limit was found");

    const hasSparkText = serialized.includes("GPT-5.3-Codex-Spark");
    if (hasSparkText && !limits.some((limit) => limit.name === "GPT-5.3-Codex-Spark")) {
      errors.push("GPT-5.3-Codex-Spark appears outside limits");
    }
  }

  if (Array.isArray(record.limits_detail)) {
    for (const detail of record.limits_detail) {
      if (!detail || typeof detail !== "object" || Array.isArray(detail)) {
        errors.push("limits_detail contains a non-object item");
        continue;
      }
      const item = detail as Record<string, unknown>;
      if (typeof item.label !== "string" || item.label.length === 0) errors.push("limits_detail item label is missing");
      if (typeof item.completeness !== "string") errors.push("limits_detail item completeness is missing");
    }
  }

  return { ok: errors.length === 0, errors };
}
