# Codex Usage Snapshot v1

`codex.usage.snapshot` is the safe telemetry shape emitted by the backend usage collector.

Raw omitted keys include `access_token`, `refresh_token`, `id_token`, `email`, `account_id`, `user_id`, `referral_beacon`, and `promo`. The full raw backend response is never emitted.

```ts
type CodexUsageSnapshot = {
  type: "codex.usage.snapshot";
  schema_version: 1;
  source: "chatgpt_backend_wham_usage" | "codex_cli_status_capture";
  observed_at: string;
  collector: {
    name: "codex_backend_usage" | "codex_cli_status_fallback";
    version: string;
    endpoint_family: "wham_usage" | "codex_cli_status";
  };
  node: {
    id: string;
    hostname?: string;
    role?: string;
    platform?: string;
  };
  account: {
    label?: string;
    plan_type?: string;
  };
  status: {
    ok: boolean;
    allowed?: boolean;
    limit_reached?: boolean;
    rate_limit_reached_type?: string | null;
    error_code?: string;
    message?: string;
    stale?: boolean;
    http_status?: number;
  };
  limits: CodexRateLimit[];
  limits_count: number;
  limits_detail: SafeCodexLimitDetail[];
  credits?: {
    has_credits?: boolean;
    unlimited?: boolean;
    overage_limit_reached?: boolean;
    balance?: string;
    approx_local_messages?: [number, number] | number[];
    approx_cloud_messages?: [number, number] | number[];
  };
  spend_control?: {
    reached?: boolean;
    individual_limit?: string | number | boolean | null;
  };
  raw_omitted_keys: string[];
};
```

`payload.limits_detail[]` is the dashboard-safe detail contract:

```ts
type SafeCodexLimitDetail = {
  key: string;
  label: string;
  source: "default" | "additional" | "credit" | "unknown";
  group_label: string | null;
  window_label: string | null;
  data_source: "backend" | "unknown";
  status: "active" | "exhausted" | "unknown";
  name: string | null;
  metered_feature: string | null;
  model: string | null;
  unit: string | null;
  total: number | null;
  used: number | null;
  remaining: number | null;
  used_percent: number | null;
  remaining_percent: number | null;
  reset_at_iso: string | null;
  reset_in_seconds: number | null;
  window_seconds: number | null;
  reset_source: "backend_absolute" | "backend_relative" | "derived_from_observed_at" | "not_reported";
  completeness: "full" | "partial" | "not_reported";
};
```

Normalizer input priority:

1. Backend `raw.limits[]`, when present, maps to `limits_detail[]` with allowlisted fields only.
2. Otherwise `raw.rate_limit` maps to the default limit.
3. `raw.additional_rate_limits[]` maps to additional limits.

Backend nested window objects are expanded into one `limits_detail[]` row per window. For current Codex backend shapes, `rate_limit.primary_window` maps to the default `5h` row, `rate_limit.secondary_window` maps to the default `weekly` row, and nested `additional_rate_limits[].rate_limit` windows carry the additional group label such as `GPT-5.3-Codex-Spark`.

Stable keys distinguish window rows:

- `default:5h`
- `default:weekly`
- `additional:GPT-5.3-Codex-Spark:5h`
- `additional:GPT-5.3-Codex-Spark:weekly`

`group_label`, `window_label`, and `data_source` are safe derived labels for display and read-model preservation. They do not contain account IDs, user IDs, emails, tokens, cookies, or raw backend payloads.

Supported aliases include total/limit/quota/cap/max/amount, used/consumed/spent, remaining/available/left, used/remaining percent variants, absolute reset variants, relative reset variants, and window/period/interval variants.

Missing backend fields are emitted as `null` in `limits_detail`; the agent does not infer absolute used, remaining, or total values from percentages. If only a relative reset is reported and `observed_at` is valid, `reset_at_iso` may be derived and `reset_source` is `derived_from_observed_at`.

For percent fields, if the backend reports exactly one of `used_percent` or `remaining_percent`, the complementary percent may be derived as `100 - reported_percent`. This is limited to percent complements and does not infer absolute counts.

`spend_control.individual_limit` is scalar-only. Nested objects are dropped to avoid backend passthrough.

The backend collector is the source for these fields. Codex `/status` text is only a display-equivalence target for operators and must not be captured or parsed as the source for backend usage snapshots.
