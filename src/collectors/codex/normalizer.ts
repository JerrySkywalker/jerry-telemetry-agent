import type { Config } from "../../config.js";
import type { CodexRateLimit, CodexUsageErrorCode, CodexUsageSnapshot, CodexUsageSummary } from "../../types/codex-usage.js";

const COLLECTOR_VERSION = "1";
const SENSITIVE_RAW_KEYS = new Set(["access_token", "refresh_token", "email", "account_id", "user_id", "referral_beacon", "promo"]);

export function normalizeCodexUsage(raw: unknown, config: Config, observedAt = new Date().toISOString()): CodexUsageSnapshot {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return errorSnapshot(config, "schema_error", "Codex usage response was not an object", observedAt);
  }
  const record = raw as Record<string, unknown>;
  const defaultLimit = normalizeLimit(record.rate_limit, "default", "default");
  const additional = Array.isArray(record.additional_rate_limits)
    ? record.additional_rate_limits.map((item) => normalizeLimit(item, "additional")).filter((item): item is CodexRateLimit => Boolean(item))
    : [];

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
    limits: [defaultLimit, ...additional].filter((item): item is CodexRateLimit => Boolean(item)),
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
    raw_omitted_keys: ["legacy_cli_status_payload"]
  };
}

export function summarizeCodexUsage(snapshot: CodexUsageSnapshot, lastSuccessAt?: string): CodexUsageSummary {
  const defaultLimits = snapshot.limits.filter((limit) => limit.scope === "default");
  const primary = defaultLimits[0];
  const secondary = defaultLimits[1];
  const resetAtIso = primary?.window?.reset_at_iso;
  const resetAfterSeconds = resetAtIso ? Math.max(0, Math.floor((Date.parse(resetAtIso) - Date.now()) / 1000)) : undefined;

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

function normalizeLimit(value: unknown, scope: "default" | "additional", fallbackName?: string): CodexRateLimit | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  const used = numberValue(record.used_percent);
  const resetAt = numberValue(record.reset_at);
  return {
    scope,
    name: stringValue(record.limit_name) ?? stringValue(record.name) ?? stringValue(record.model_slug) ?? fallbackName ?? "additional",
    metered_feature: stringValue(record.metered_feature),
    used_percent: used,
    remaining_percent: used === undefined ? undefined : Math.max(0, 100 - used),
    window: compactObject({
      window_seconds: numberValue(record.limit_window_seconds),
      reset_at_epoch: resetAt,
      reset_at_iso: resetAt === undefined ? undefined : new Date(resetAt * 1000).toISOString()
    })
  };
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
    individual_limit: record.individual_limit ?? null
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

function compactObject<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as T;
}
