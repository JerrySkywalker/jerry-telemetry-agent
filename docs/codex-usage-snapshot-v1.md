# Codex Usage Snapshot v1

`codex.usage.snapshot` is the safe telemetry shape emitted by the backend usage collector.

Raw omitted keys include `access_token`, `refresh_token`, `email`, `account_id`, `user_id`, `referral_beacon`, and `promo`. The full raw backend response is never emitted.

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
  };
  limits: CodexRateLimit[];
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
    individual_limit?: unknown | null;
  };
  raw_omitted_keys: string[];
};
```

Default `raw.rate_limit` maps to `limits[0]` with `scope: "default"` and `name: "default"`. `raw.additional_rate_limits[]` maps to `scope: "additional"` with `name`, `metered_feature`, `window_seconds`, `reset_at_epoch`, `reset_at_iso`, `used_percent`, and `remaining_percent`.
