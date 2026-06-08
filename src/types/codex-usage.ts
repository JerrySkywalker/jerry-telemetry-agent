export type CodexUsageSource = "chatgpt_backend_wham_usage" | "codex_cli_status_capture";

export interface CodexRateWindow {
  window_seconds?: number;
  reset_at_epoch?: number;
  reset_at_iso?: string;
}

export interface CodexRateLimit {
  scope: "default" | "additional";
  name: string;
  metered_feature?: string;
  used_percent?: number;
  remaining_percent?: number;
  window?: CodexRateWindow;
}

export interface CodexUsageSnapshot {
  type: "codex.usage.snapshot";
  schema_version: 1;
  source: CodexUsageSource;
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
    error_code?: CodexUsageErrorCode | string;
    message?: string;
    stale?: boolean;
    http_status?: number;
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
}

export type CodexUsageErrorCode =
  | "auth_json_missing"
  | "access_token_missing"
  | "http_401"
  | "http_403"
  | "http_404"
  | "http_429"
  | "http_5xx"
  | "network_error"
  | "schema_error";

export interface CodexUsageSummary {
  ok: boolean;
  stale?: boolean;
  node_id: string;
  plan_type?: string;
  default_limit?: {
    primary?: Pick<CodexRateLimit, "used_percent" | "remaining_percent">;
    secondary?: Pick<CodexRateLimit, "used_percent" | "remaining_percent">;
    reset_after_seconds?: number;
    reset_at_iso?: string;
  };
  additional_limits: CodexRateLimit[];
  credits?: {
    has_credits?: boolean;
    unlimited?: boolean;
    overage_limit_reached?: boolean;
    balance?: string;
  };
  spend_control?: {
    reached?: boolean;
  };
  observed_at: string;
  last_success_at?: string;
}
