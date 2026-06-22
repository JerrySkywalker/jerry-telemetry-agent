export interface AgentHealthSnapshot {
  type: "telemetry.agent.health";
  schema_version: 1;
  observed_at: string;
  node: {
    id: string;
    hostname: string;
    region: string;
    platform: string;
  };
  agent: {
    name: "jerry-telemetry-agent";
    version: string;
    mode: "once" | "daemon";
    uptime_seconds: number;
    started_at: string;
  };
  status: {
    ok: boolean;
    degraded: boolean;
    message: string;
  };
  collectors: AgentHealthCollector[];
  outputs: {
    file_enabled: boolean;
    http_enabled: boolean;
    last_http_success_at?: string | null;
    last_http_error_at?: string | null;
    pending_spool_count: number;
  };
  config: {
    poll_interval_seconds: number;
    provider: string;
    tmux_fallback_enabled: boolean;
    health_server_enabled: boolean;
  };
  security: {
    auth_dir_mounted_readonly: boolean | "unknown";
    node_secret_present: boolean;
  };
  raw_omitted_keys: string[];
}

export interface AgentHealthCollector {
  name: string;
  enabled: boolean;
  interval_seconds?: number | null;
  last_success_at?: string | null;
  last_error_at?: string | null;
  last_error_code?: string | null;
  latest_payload_status_ok?: boolean | null;
  latest_limits_count?: number | null;
}
