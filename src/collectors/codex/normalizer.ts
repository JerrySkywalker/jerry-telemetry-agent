import type { Config } from "../../config.js";
import type {
  CodexRateLimit,
  CodexUsageErrorCode,
  CodexUsageSnapshot,
  CodexUsageSummary,
  SafeCodexLimitDetail,
  SafeCodexLimitResetSource
} from "../../types/codex-usage.js";

const COLLECTOR_VERSION = "1";
const SENSITIVE_RAW_KEYS = new Set(["access_token", "refresh_token", "id_token", "email", "account_id", "user_id", "referral_beacon", "promo"]);

export function normalizeCodexUsage(raw: unknown, config: Config, observedAt = new Date().toISOString()): CodexUsageSnapshot {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return errorSnapshot(config, "schema_error", "Codex usage response was not an object", observedAt);
  }
  const record = raw as Record<string, unknown>;
  const defaultLimit = normalizeLimit(record.rate_limit, "default", "default", observedAt);
  const additional = Array.isArray(record.additional_rate_limits)
    ? record.additional_rate_limits.map((item) => normalizeLimit(item, "additional", undefined, observedAt)).filter((item): item is CodexRateLimit => Boolean(item))
    : [];
  const backendLimits = Array.isArray(record.limits)
    ? record.limits.map((item) => normalizeBackendLimit(item, observedAt)).filter((item): item is CodexRateLimit => Boolean(item))
    : [];
  const explicitLimits = [defaultLimit, ...additional].filter((item): item is CodexRateLimit => Boolean(item));
  const limits = backendLimits.length > 0 ? backendLimits : explicitLimits;
  const limitsDetail = limits.map((limit, index) => limitToDetail(limit, index, observedAt));

  return {
    type: "codex.usage.snapshot",
    schema_version: 1,
    source: "chatgpt_backend_wham_usage",
    observed_at: observedAt,
    collector: {
      name: "codex_backend_usage",
      version: COLLECTOR_VERSION,
      endpoint_family: "wham_usage"
    },
    node: nodeInfo(config),
    account: compactObject({
      label: config.accountLabel || undefined,
      plan_type: stringValue(record.plan_type)
    }),
    status: compactObject({
      ok: true,
      allowed: booleanValue(record.allowed),
      limit_reached: booleanValue(record.limit_reached),
      rate_limit_reached_type: nullableString(record.rate_limit_reached_type)
    }),
    limits,
    limits_count: limits.length,
    limits_detail: limitsDetail,
    credits: normalizeCredits(record.credits),
    spend_control: normalizeSpendControl(record.spend_control),
    raw_omitted_keys: omittedKeys(record)
  };
}

export function errorSnapshot(
  config: Config,
  errorCode: CodexUsageErrorCode,
  message: string,
  observedAt = new Date().toISOString(),
  stale = false,
  diagnostics: { httpStatus?: number } = {}
): CodexUsageSnapshot {
  return {
    type: "codex.usage.snapshot",
    schema_version: 1,
    source: "chatgpt_backend_wham_usage",
    observed_at: observedAt,
    collector: {
      name: "codex_backend_usage",
      version: COLLECTOR_VERSION,
      endpoint_family: "wham_usage"
    },
    node: nodeInfo(config),
    account: compactObject({ label: config.accountLabel || undefined }),
    status: {
      ok: false,
      error_code: errorCode,
      message,
      stale,
      http_status: diagnostics.httpStatus
    },
    limits: [],
    limits_count: 0,
    limits_detail: [],
    raw_omitted_keys: []
  };
}

export function fallbackSnapshot(payload: Record<string, unknown>, config: Config, observedAt = new Date().toISOString()): CodexUsageSnapshot {
  return {
    type: "codex.usage.snapshot",
    schema_version: 1,
    source: "codex_cli_status_capture",
    observed_at: observedAt,
    collector: {
      name: "codex_cli_status_fallback",
      version: COLLECTOR_VERSION,
      endpoint_family: "codex_cli_status"
    },
    node: nodeInfo(config),
    account: compactObject({ label: config.accountLabel || undefined }),
    status: {
      ok: true,
      message: stringValue(payload.status) ?? "captured from Codex CLI status fallback"
    },
    limits: [],
    limits_count: 0,
    limits_detail: [],
    raw_omitted_keys: ["legacy_cli_status_payload"]
  };
}

export function summarizeCodexUsage(snapshot: CodexUsageSnapshot, lastSuccessAt?: string): CodexUsageSummary {
  const defaultLimits = snapshot.limits.filter((limit) => limit.scope === "default");
  const primary = defaultLimits[0];
  const secondary = defaultLimits[1];
  const resetAtIso = primary?.window?.reset_at_iso;
  const resetAfterSeconds = resetAtIso ? Math.max(0, Math.floor((Date.parse(resetAtIso) - Date.now()) / 1000)) : undefined;
  const limitsDetail = snapshot.limits_detail ?? snapshot.limits.map((limit, index) => limitToDetail(limit, index, snapshot.observed_at));
  const defaultLimitDetail = limitsDetail.find((limit) => limit.source === "default" || limit.name === "default" || limit.label.toLowerCase() === "default");
  const sparkLimitDetail = limitsDetail.find((limit) => {
    const text = `${limit.name ?? ""} ${limit.label} ${limit.model ?? ""} ${limit.metered_feature ?? ""}`.toLowerCase();
    return text.includes("gpt-5.3-codex-spark") || text.includes("spark");
  });

  return {
    ok: snapshot.status.ok,
    stale: snapshot.status.stale,
    node_id: snapshot.node.id,
    plan_type: snapshot.account.plan_type,
    default_limit: compactObject({
      primary: pickPercent(primary),
      secondary: pickPercent(secondary),
      reset_after_seconds: resetAfterSeconds,
      reset_at_iso: resetAtIso
    }),
    additional_limits: snapshot.limits.filter((limit) => limit.scope === "additional"),
    limits_count: limitsDetail.length,
    limits_detail: limitsDetail,
    default_limit_detail: defaultLimitDetail,
    spark_limit_detail: sparkLimitDetail,
    credits: snapshot.credits
      ? compactObject({
          has_credits: snapshot.credits.has_credits,
          unlimited: snapshot.credits.unlimited,
          overage_limit_reached: snapshot.credits.overage_limit_reached,
          balance: snapshot.credits.balance
        })
      : undefined,
    spend_control: snapshot.spend_control ? compactObject({ reached: snapshot.spend_control.reached }) : undefined,
    observed_at: snapshot.observed_at,
    last_success_at: lastSuccessAt
  };
}

function normalizeBackendLimit(value: unknown, observedAt: string): CodexRateLimit | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  const detailSource = limitSource(record);
  const scope = detailSource === "default" ? "default" : "additional";
  return normalizeLimit(value, scope, undefined, observedAt, detailSource);
}

function normalizeLimit(
  value: unknown,
  scope: "default" | "additional",
  fallbackName?: string,
  observedAt?: string,
  detailSource: CodexRateLimit["detail_source"] = scope
): CodexRateLimit | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  const used = percentValue(pickNumber(record, ["used_percent", "percent_used", "usage_percent"]));
  const remaining = percentValue(pickNumber(record, ["remaining_percent", "percent_remaining"]));
  const absoluteReset = normalizeResetAt(pickValue(record, ["reset_at", "resetAt", "reset_time", "resetTime", "reset_at_iso", "resets_at"]));
  const resetInSeconds = pickNumber(record, ["reset_in_seconds", "reset_after_seconds", "seconds_until_reset"]);
  const derivedResetAtIso = absoluteReset?.iso ?? deriveResetAtIso(observedAt, resetInSeconds);
  const resetSource: SafeCodexLimitResetSource | undefined = absoluteReset
    ? "backend_absolute"
    : resetInSeconds !== undefined && derivedResetAtIso
      ? "derived_from_observed_at"
      : resetInSeconds !== undefined
        ? "backend_relative"
        : undefined;
  return {
    scope,
    detail_source: detailSource,
    name:
      pickString(record, ["limit_name", "name", "label", "display_name", "metered_feature", "model", "model_slug"]) ??
      fallbackName ??
      "additional",
    metered_feature: pickString(record, ["metered_feature"]),
    model: pickString(record, ["model", "model_slug"]),
    unit: pickString(record, ["unit"]),
    total: pickNumber(record, ["total", "limit", "quota", "cap", "max", "amount", "credits_total"]),
    used: pickNumber(record, ["used", "consumed", "spent", "credits_used"]),
    remaining: pickNumber(record, ["remaining", "available", "left", "credits_remaining"]),
    used_percent: used,
    remaining_percent: remaining ?? (used === undefined ? undefined : Math.max(0, 100 - used)),
    window: compactObject({
      window_seconds: pickNumber(record, ["window_seconds", "period_seconds", "interval_seconds", "quota_window_seconds", "limit_window_seconds"]),
      reset_at_epoch: absoluteReset?.epoch,
      reset_at_iso: derivedResetAtIso,
      reset_in_seconds: resetInSeconds,
      reset_source: resetSource
    })
  };
}

function limitToDetail(limit: CodexRateLimit, index: number, observedAt: string): SafeCodexLimitDetail {
  const source = limit.detail_source ?? limit.scope;
  const resetAtIso = limit.window?.reset_at_iso ?? null;
  const resetInSeconds = limit.window?.reset_in_seconds ?? secondsUntilReset(observedAt, resetAtIso);
  const reported = [
    limit.total,
    limit.used,
    limit.remaining,
    limit.used_percent,
    limit.remaining_percent,
    limit.window?.reset_at_iso,
    limit.window?.reset_in_seconds,
    limit.window?.window_seconds
  ].some((item) => item !== undefined && item !== null);
  const complete = limit.total !== undefined && limit.used !== undefined && limit.remaining !== undefined && resetAtIso !== null;
  return {
    key: `${source}:${limit.name || index}`,
    label: limit.name || (limit.scope === "default" ? "Default" : "Additional"),
    source,
    status: limitStatus(limit),
    name: limit.name ?? null,
    metered_feature: limit.metered_feature ?? null,
    model: limit.model ?? null,
    unit: limit.unit ?? null,
    total: limit.total ?? null,
    used: limit.used ?? null,
    remaining: limit.remaining ?? null,
    used_percent: limit.used_percent ?? null,
    remaining_percent: limit.remaining_percent ?? null,
    reset_at_iso: resetAtIso,
    reset_in_seconds: resetInSeconds,
    window_seconds: limit.window?.window_seconds ?? null,
    reset_source: limit.window?.reset_source ?? (resetAtIso ? "backend_absolute" : "not_reported"),
    completeness: complete ? "full" : reported ? "partial" : "not_reported"
  };
}

function limitStatus(limit: CodexRateLimit): SafeCodexLimitDetail["status"] {
  if (limit.remaining === 0 || limit.remaining_percent === 0 || (limit.used_percent !== undefined && limit.used_percent >= 100)) return "exhausted";
  if (
    (limit.remaining !== undefined && limit.remaining > 0) ||
    (limit.remaining_percent !== undefined && limit.remaining_percent > 0) ||
    (limit.used_percent !== undefined && limit.used_percent < 100)
  ) {
    return "active";
  }
  return "unknown";
}

function limitSource(record: Record<string, unknown>): SafeCodexLimitDetail["source"] {
  const raw = pickString(record, ["source", "scope", "type", "kind"]);
  if (raw === "default" || raw === "additional" || raw === "credit" || raw === "unknown") return raw;
  const text = `${pickString(record, ["name", "label", "display_name", "limit_name"]) ?? ""} ${pickString(record, ["metered_feature", "model", "model_slug"]) ?? ""}`.toLowerCase();
  if (text.includes("default")) return "default";
  if (text.includes("credit")) return "credit";
  if (text.includes("spark") || text.includes("additional")) return "additional";
  return "unknown";
}

function normalizeCredits(value: unknown): CodexUsageSnapshot["credits"] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  return compactObject({
    has_credits: booleanValue(record.has_credits),
    unlimited: booleanValue(record.unlimited),
    overage_limit_reached: booleanValue(record.overage_limit_reached),
    balance: stringValue(record.balance),
    approx_local_messages: numberTuple(record.approx_local_messages),
    approx_cloud_messages: numberTuple(record.approx_cloud_messages)
  });
}

function normalizeSpendControl(value: unknown): CodexUsageSnapshot["spend_control"] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  return compactObject({
    reached: booleanValue(record.reached),
    individual_limit: scalarValue(record.individual_limit) ?? null
  });
}

function nodeInfo(config: Config): CodexUsageSnapshot["node"] {
  return compactObject({
    id: config.nodeId,
    hostname: config.hostname || undefined,
    role: config.nodeRole || undefined,
    platform: config.platform || undefined
  });
}

function omittedKeys(record: Record<string, unknown>): string[] {
  return Object.keys(record).some((key) => SENSITIVE_RAW_KEYS.has(key)) ? ["sensitive_raw_fields"] : [];
}

function pickPercent(limit: CodexRateLimit | undefined): Pick<CodexRateLimit, "used_percent" | "remaining_percent"> | undefined {
  if (!limit) return undefined;
  return compactObject({ used_percent: limit.used_percent, remaining_percent: limit.remaining_percent });
}

function numberTuple(value: unknown): number[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const numbers = value.filter((item): item is number => typeof item === "number" && Number.isFinite(item));
  return numbers.length > 0 ? numbers : undefined;
}

function pickValue(record: Record<string, unknown>, names: string[]): unknown {
  for (const name of names) {
    if (record[name] !== undefined && record[name] !== null) return record[name];
  }
  return undefined;
}

function pickNumber(record: Record<string, unknown>, names: string[]): number | undefined {
  for (const name of names) {
    const value = numberValue(record[name]);
    if (value !== undefined) return value;
  }
  return undefined;
}

function pickString(record: Record<string, unknown>, names: string[]): string | undefined {
  for (const name of names) {
    const value = stringValue(record[name]);
    if (value !== undefined) return value;
  }
  return undefined;
}

function percentValue(value: number | undefined): number | undefined {
  if (value === undefined) return undefined;
  if (value >= 0 && value <= 1) return value * 100;
  return value;
}

function normalizeResetAt(value: unknown): { iso: string; epoch?: number } | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    const epoch = value > 10_000_000_000 ? Math.floor(value / 1000) : value;
    const date = new Date(epoch * 1000);
    return Number.isNaN(date.getTime()) ? undefined : { epoch, iso: date.toISOString() };
  }
  if (typeof value === "string" && value.length > 0) {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? undefined : { iso: new Date(parsed).toISOString() };
  }
  return undefined;
}

function deriveResetAtIso(observedAt: string | undefined, resetInSeconds: number | undefined): string | undefined {
  if (resetInSeconds === undefined || !observedAt) return undefined;
  const observedMs = Date.parse(observedAt);
  if (!Number.isFinite(observedMs)) return undefined;
  return new Date(observedMs + resetInSeconds * 1000).toISOString();
}

function secondsUntilReset(observedAt: string, resetAtIso: string | null): number | null {
  if (!resetAtIso) return null;
  const observedMs = Date.parse(observedAt);
  const resetMs = Date.parse(resetAtIso);
  if (!Number.isFinite(observedMs) || !Number.isFinite(resetMs)) return null;
  return Math.max(0, Math.floor((resetMs - observedMs) / 1000));
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function nullableString(value: unknown): string | null | undefined {
  if (value === null) return null;
  return stringValue(value);
}

function booleanValue(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function scalarValue(value: unknown): string | number | boolean | undefined {
  if (typeof value === "string" && value.length > 0) return value;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "boolean") return value;
  return undefined;
}

function compactObject<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as T;
}
