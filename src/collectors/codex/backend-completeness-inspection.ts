import type { CodexUsageSnapshot, SafeCodexLimitDetail } from "../../types/codex-usage.js";

export type CodexBackendRequiredRow = "default_5h" | "default_weekly" | "spark_5h" | "spark_weekly";

export interface CodexBackendCompletenessRow {
  row: CodexBackendRequiredRow;
  found: boolean;
  normalized_found: boolean;
  remaining_percent_present: boolean;
  used_percent_present: boolean;
  reset_present: boolean;
  window_seconds_present: boolean;
  completeness: SafeCodexLimitDetail["completeness"] | "missing";
}

export interface CodexBackendCompletenessInspection {
  backend_response_ok: boolean;
  candidate_limit_row_count: number;
  candidate_window_labels: string[];
  candidate_group_labels: string[];
  default_5h_found: boolean;
  default_weekly_found: boolean;
  spark_5h_found: boolean;
  spark_weekly_found: boolean;
  remaining_percent_present_by_row: Record<CodexBackendRequiredRow, boolean>;
  reset_present_by_row: Record<CodexBackendRequiredRow, boolean>;
  window_seconds_present_by_row: Record<CodexBackendRequiredRow, boolean>;
  rows: Record<CodexBackendRequiredRow, CodexBackendCompletenessRow>;
  normalizer_gap_detected: boolean;
  source_gap_detected: boolean;
}

interface RawWindowSummary {
  row: CodexBackendRequiredRow;
  group_label: "default" | "GPT-5.3-Codex-Spark";
  window_label: "5h" | "weekly";
  remaining_percent_present: boolean;
  used_percent_present: boolean;
  reset_present: boolean;
  window_seconds_present: boolean;
}

const REQUIRED_ROWS: CodexBackendRequiredRow[] = ["default_5h", "default_weekly", "spark_5h", "spark_weekly"];

export function inspectBackendUsageCompleteness(raw: unknown, snapshot?: CodexUsageSnapshot): CodexBackendCompletenessInspection {
  const rawRows = collectRawRows(raw);
  const normalizedRows = collectNormalizedRows(snapshot);
  const rows = Object.fromEntries(
    REQUIRED_ROWS.map((row) => {
      const rawRow = rawRows.find((item) => item.row === row);
      const normalizedRow = normalizedRows.find((item) => item.row === row);
      return [
        row,
        {
          row,
          found: Boolean(rawRow),
          normalized_found: Boolean(normalizedRow),
          remaining_percent_present: Boolean(normalizedRow?.remaining_percent_present ?? rawRow?.remaining_percent_present),
          used_percent_present: Boolean(normalizedRow?.used_percent_present ?? rawRow?.used_percent_present),
          reset_present: Boolean(normalizedRow?.reset_present ?? rawRow?.reset_present),
          window_seconds_present: Boolean(normalizedRow?.window_seconds_present ?? rawRow?.window_seconds_present),
          completeness: normalizedRow?.completeness ?? "missing"
        } satisfies CodexBackendCompletenessRow
      ];
    })
  ) as Record<CodexBackendRequiredRow, CodexBackendCompletenessRow>;
  const rawComplete = REQUIRED_ROWS.every((row) => rows[row].found);
  const normalizedComplete = REQUIRED_ROWS.every((row) => rows[row].normalized_found);

  return {
    backend_response_ok: Boolean(raw && typeof raw === "object" && !Array.isArray(raw)),
    candidate_limit_row_count: rawRows.length,
    candidate_window_labels: [...new Set(rawRows.map((row) => row.window_label))].sort(),
    candidate_group_labels: [...new Set(rawRows.map((row) => row.group_label))].sort(),
    default_5h_found: rows.default_5h.found,
    default_weekly_found: rows.default_weekly.found,
    spark_5h_found: rows.spark_5h.found,
    spark_weekly_found: rows.spark_weekly.found,
    remaining_percent_present_by_row: pickRowFlag(rows, "remaining_percent_present"),
    reset_present_by_row: pickRowFlag(rows, "reset_present"),
    window_seconds_present_by_row: pickRowFlag(rows, "window_seconds_present"),
    rows,
    normalizer_gap_detected: rawComplete && !normalizedComplete,
    source_gap_detected: !rawComplete
  };
}

function collectRawRows(raw: unknown): RawWindowSummary[] {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return [];
  const record = raw as Record<string, unknown>;
  return [
    ...collectRateLimitRows(record.rate_limit, "default"),
    ...(Array.isArray(record.additional_rate_limits)
      ? record.additional_rate_limits.flatMap((item) => collectAdditionalRateLimitRows(item))
      : []),
    ...(Array.isArray(record.limits) ? record.limits.flatMap((item) => collectLimitArrayRows(item)) : [])
  ];
}

function collectAdditionalRateLimitRows(value: unknown): RawWindowSummary[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  const record = value as Record<string, unknown>;
  if (!isSparkGroup(record)) return [];
  return collectRateLimitRows(record.rate_limit ?? record, "GPT-5.3-Codex-Spark");
}

function collectLimitArrayRows(value: unknown): RawWindowSummary[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  const record = value as Record<string, unknown>;
  const group = groupFromRecord(record);
  return group ? collectRateLimitRows(record, group) : [];
}

function collectRateLimitRows(value: unknown, group: "default" | "GPT-5.3-Codex-Spark"): RawWindowSummary[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  const record = value as Record<string, unknown>;
  const directWindow = windowFromRecord(record, undefined);
  if (directWindow) return [rawSummary(group, directWindow, record)];

  return Object.entries(record)
    .filter(([, item]) => item && typeof item === "object" && !Array.isArray(item))
    .map(([key, item]) => {
      const window = windowFromRecord(item as Record<string, unknown>, key);
      return window ? rawSummary(group, window, item as Record<string, unknown>) : undefined;
    })
    .filter((item): item is RawWindowSummary => Boolean(item));
}

function rawSummary(group: "default" | "GPT-5.3-Codex-Spark", window: "5h" | "weekly", record: Record<string, unknown>): RawWindowSummary {
  return {
    row: rowName(group, window),
    group_label: group,
    window_label: window,
    remaining_percent_present: pickNumber(record, ["remaining_percent", "percent_remaining"]) !== undefined,
    used_percent_present: pickNumber(record, ["used_percent", "percent_used", "usage_percent"]) !== undefined,
    reset_present:
      pickNumber(record, ["reset_in_seconds", "reset_after_seconds", "seconds_until_reset"]) !== undefined ||
      pickValue(record, ["reset_at", "resetAt", "reset_time", "resetTime", "reset_at_iso", "resets_at"]) !== undefined,
    window_seconds_present: pickNumber(record, ["window_seconds", "period_seconds", "interval_seconds", "quota_window_seconds", "limit_window_seconds"]) !== undefined
  };
}

function collectNormalizedRows(snapshot: CodexUsageSnapshot | undefined): CodexBackendCompletenessRow[] {
  if (!snapshot) return [];
  return snapshot.limits_detail
    .map((detail): CodexBackendCompletenessRow | undefined => {
      const row = rowFromDetail(detail);
      if (!row) return undefined;
      return {
        row,
        found: true,
        normalized_found: true,
        remaining_percent_present: detail.remaining_percent !== null,
        used_percent_present: detail.used_percent !== null,
        reset_present: detail.reset_at_iso !== null || detail.reset_in_seconds !== null,
        window_seconds_present: detail.window_seconds !== null,
        completeness: detail.completeness
      } satisfies CodexBackendCompletenessRow;
    })
    .filter((item): item is CodexBackendCompletenessRow => Boolean(item));
}

function rowFromDetail(detail: SafeCodexLimitDetail): CodexBackendRequiredRow | undefined {
  if (detail.group_label === "default" && detail.window_label === "5h") return "default_5h";
  if (detail.group_label === "default" && detail.window_label === "weekly") return "default_weekly";
  if (detail.group_label === "GPT-5.3-Codex-Spark" && detail.window_label === "5h") return "spark_5h";
  if (detail.group_label === "GPT-5.3-Codex-Spark" && detail.window_label === "weekly") return "spark_weekly";
  return undefined;
}

function rowName(group: "default" | "GPT-5.3-Codex-Spark", window: "5h" | "weekly"): CodexBackendRequiredRow {
  if (group === "default" && window === "5h") return "default_5h";
  if (group === "default" && window === "weekly") return "default_weekly";
  if (group === "GPT-5.3-Codex-Spark" && window === "5h") return "spark_5h";
  return "spark_weekly";
}

function groupFromRecord(record: Record<string, unknown>): "default" | "GPT-5.3-Codex-Spark" | undefined {
  const text = [
    pickString(record, ["source", "scope", "type", "kind"]),
    pickString(record, ["limit_name", "name", "label", "display_name"]),
    pickString(record, ["metered_feature", "model", "model_slug"])
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  if (text.includes("default") || text.includes("base")) return "default";
  if (text.includes("gpt-5.3-codex-spark") || text.includes("spark")) return "GPT-5.3-Codex-Spark";
  return undefined;
}

function isSparkGroup(record: Record<string, unknown>): boolean {
  return groupFromRecord(record) === "GPT-5.3-Codex-Spark";
}

function windowFromRecord(record: Record<string, unknown>, key: string | undefined): "5h" | "weekly" | undefined {
  const seconds = pickNumber(record, ["window_seconds", "period_seconds", "interval_seconds", "quota_window_seconds", "limit_window_seconds"]);
  if (seconds !== undefined) {
    if (Math.round(seconds) === 18_000) return "5h";
    if (Math.round(seconds) === 604_800) return "weekly";
  }
  const text = [
    key,
    pickString(record, ["window_label", "window", "period", "interval", "label", "display_name", "limit_name"])
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  if (text.includes("secondary") || text.includes("weekly") || text.includes("week")) return "weekly";
  if (text.includes("primary") || text.includes("5h") || text.includes("5 h") || text.includes("five_hour")) return "5h";
  return undefined;
}

function pickRowFlag(
  rows: Record<CodexBackendRequiredRow, CodexBackendCompletenessRow>,
  key: "remaining_percent_present" | "reset_present" | "window_seconds_present"
): Record<CodexBackendRequiredRow, boolean> {
  return {
    default_5h: rows.default_5h[key],
    default_weekly: rows.default_weekly[key],
    spark_5h: rows.spark_5h[key],
    spark_weekly: rows.spark_weekly[key]
  };
}

function pickNumber(record: Record<string, unknown>, names: string[]): number | undefined {
  for (const name of names) {
    const value = record[name];
    if (typeof value === "number" && Number.isFinite(value)) return value;
  }
  return undefined;
}

function pickString(record: Record<string, unknown>, names: string[]): string | undefined {
  for (const name of names) {
    const value = record[name];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

function pickValue(record: Record<string, unknown>, names: string[]): unknown {
  for (const name of names) {
    if (record[name] !== undefined && record[name] !== null) return record[name];
  }
  return undefined;
}
