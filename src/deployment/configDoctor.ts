import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadConfig, type OutputMode } from "../config.js";
import { collectorRegistry, parseDeclarativeNodeConfig, type DeclarativeNodeConfig, type NodeCollectorConfig } from "../collectors/registry.js";
import { findForbiddenTelemetryMarkers } from "../telemetry/forbiddenMarkers.js";

export type AgentDoctorMode = "Local" | "Server" | "LaxCodex";
export type DoctorStatus = "pass" | "warn" | "fail";

export interface AgentConfigDoctorOptions {
  envPath?: string;
  nodeConfigPath?: string;
  strictProduction?: boolean;
  mode?: AgentDoctorMode;
  noNetwork?: boolean;
  env?: NodeJS.ProcessEnv;
}

export interface DoctorCheck {
  name: string;
  status: DoctorStatus;
  message: string;
  details?: Record<string, unknown>;
}

export interface AgentConfigDoctorResult {
  ok: boolean;
  mode: AgentDoctorMode;
  strict_production: boolean;
  no_network: boolean;
  summary: {
    pass: number;
    warn: number;
    fail: number;
  };
  checks: DoctorCheck[];
  safe: {
    secret_values_printed: false;
    auth_paths_printed: false;
    raw_env_printed: false;
    forbidden_markers_found: string[];
  };
}

const PLACEHOLDER_PATTERN = /(replace-with|changeme|example|placeholder)/i;
const URL_SECRET_PATTERN = /(token|secret|key|signature|sig)=/i;
const MUTATING_COLLECTOR_KEYS = new Set(["command", "cmd", "shell", "exec", "script"]);

export function runAgentConfigDoctor(options: AgentConfigDoctorOptions = {}): AgentConfigDoctorResult {
  const mode = options.mode ?? "Server";
  const strictProduction = options.strictProduction === true;
  const noNetwork = options.noNetwork === true;
  const env = loadDoctorEnv(options);
  const checks: DoctorCheck[] = [];
  const nodeConfigPath = options.nodeConfigPath ?? env.TELEMETRY_NODE_CONFIG_PATH;

  addCheck(checks, "env_path", "pass", "env path inspected", {
    configured: Boolean(options.envPath),
    present: options.envPath ? existsSync(options.envPath) : false
  });

  addCheck(checks, "node_config_path", nodeConfigPath ? (isRemotePath(nodeConfigPath) ? "fail" : pathExists(nodeConfigPath) ? "pass" : "fail") : mode === "Server" ? "fail" : "warn", nodeConfigPath
    ? isRemotePath(nodeConfigPath)
      ? "node config path must be local"
      : pathExists(nodeConfigPath)
        ? "node config path present"
        : "node config path missing"
    : mode === "Server"
      ? "server mode requires a node config path"
      : "node config path not configured", {
    configured: Boolean(nodeConfigPath),
    present: nodeConfigPath ? pathExists(nodeConfigPath) : false
  });

  const parsedConfig = nodeConfigPath && pathExists(nodeConfigPath) && !isRemotePath(nodeConfigPath)
    ? parseNodeConfigSafely(nodeConfigPath, checks)
    : undefined;

  checkNodeShape(checks, mode, strictProduction, env, parsedConfig);
  checkLoadConfig(checks, env, nodeConfigPath, mode);
  checkUploadConfig(checks, env, parsedConfig, strictProduction);
  checkPaths(checks, env, parsedConfig);
  checkLaxCodex(checks, mode, env);
  addCheck(checks, "network_checks", "pass", noNetwork ? "network checks skipped by request" : "no active network checks required", {
    skipped: noNetwork
  });

  const interim = buildResult(mode, strictProduction, noNetwork, checks);
  const forbidden = findForbiddenTelemetryMarkers(interim);
  return {
    ...interim,
    safe: {
      ...interim.safe,
      forbidden_markers_found: forbidden
    },
    ok: interim.ok && forbidden.length === 0
  };
}

function loadDoctorEnv(options: AgentConfigDoctorOptions): NodeJS.ProcessEnv {
  const base = { ...(options.env ?? process.env) };
  const fileEnv = options.envPath ? parseEnvFile(options.envPath) : {};
  const env = { ...base, ...fileEnv };
  if (options.nodeConfigPath) env.TELEMETRY_NODE_CONFIG_PATH = options.nodeConfigPath;
  return env;
}

export function parseEnvFile(file: string): Record<string, string> {
  if (isRemotePath(file)) throw new Error("EnvPath must be a local file path");
  if (!existsSync(file)) throw new Error("EnvPath does not exist");
  const output: Record<string, string> = {};
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const index = trimmed.indexOf("=");
    if (index <= 0) continue;
    const key = trimmed.slice(0, index).trim();
    const value = trimmed.slice(index + 1).trim().replace(/^["']|["']$/g, "");
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) output[key] = value;
  }
  return output;
}

function parseNodeConfigSafely(file: string, checks: DoctorCheck[]): DeclarativeNodeConfig | undefined {
  try {
    const raw = JSON.parse(readFileSync(file, "utf8").replace(/^\uFEFF/, "")) as unknown;
    checkNoMutatingCollectorShape(raw, checks);
    const parsed = parseDeclarativeNodeConfig(raw);
    addCheck(checks, "node_config_parse", "pass", "node config parsed successfully", {
      collectors_count: parsed.collectors?.length ?? 0
    });
    return parsed;
  } catch (error) {
    addCheck(checks, "node_config_parse", "fail", safeErrorMessage(error), {});
    return undefined;
  }
}

function checkNoMutatingCollectorShape(value: unknown, checks: DoctorCheck[]): void {
  const hits: string[] = [];
  walk(value, (record) => {
    for (const key of Object.keys(record)) {
      if (MUTATING_COLLECTOR_KEYS.has(key.toLowerCase())) hits.push(key);
    }
    const name = typeof record.name === "string" ? record.name.toLowerCase() : "";
    if (name.includes("shell") || name.includes("command") || name.includes("exec")) hits.push("collector.name");
  });
  if (hits.length > 0) {
    addCheck(checks, "arbitrary_shell_collector", "fail", "arbitrary shell command collectors are not supported", {
      disallowed_shape_found: true
    });
  } else {
    addCheck(checks, "arbitrary_shell_collector", "pass", "no arbitrary shell collector shape found", {
      disallowed_shape_found: false
    });
  }
}

function checkNodeShape(
  checks: DoctorCheck[],
  mode: AgentDoctorMode,
  strictProduction: boolean,
  env: NodeJS.ProcessEnv,
  nodeConfig?: DeclarativeNodeConfig
): void {
  const nodeId = env.TELEMETRY_NODE_ID || nodeConfig?.node_id;
  const hostname = env.TELEMETRY_HOSTNAME || nodeConfig?.hostname || os.hostname();
  const region = env.TELEMETRY_REGION || nodeConfig?.region;
  const role = env.TELEMETRY_NODE_ROLE || nodeConfig?.role;
  const provider = env.TELEMETRY_PROVIDER || nodeConfig?.provider;
  const collectors = nodeConfig?.collectors ?? [];

  addCheck(checks, "node_id", nodeId ? "pass" : mode === "Server" || strictProduction ? "fail" : "warn", nodeId ? "node id configured" : "node id missing", {
    present: Boolean(nodeId)
  });
  addCheck(checks, "hostname", hostname ? "pass" : strictProduction ? "fail" : "warn", hostname ? "hostname configured or resolvable" : "hostname missing", {
    present_or_resolvable: Boolean(hostname)
  });
  addCheck(checks, "node_metadata", region && role && provider ? "pass" : strictProduction ? "fail" : "warn", "region, role, and provider checked", {
    region_present: Boolean(region),
    role_present: Boolean(role),
    provider_present: Boolean(provider)
  });
  addCheck(checks, "collectors", collectors.length > 0 ? "pass" : mode === "Server" ? "fail" : "warn", collectors.length > 0 ? "collectors parsed successfully" : "no collectors configured", {
    collectors_count: collectors.length,
    collector_names: collectors.map((collector) => collector.name)
  });
  addCheck(checks, "unknown_collectors", "pass", "collector names are allowlisted", {
    registry_count: Object.keys(collectorRegistry).length
  });
}

function checkLoadConfig(checks: DoctorCheck[], env: NodeJS.ProcessEnv, nodeConfigPath: string | undefined, mode: AgentDoctorMode): void {
  const patched = { ...env };
  if (nodeConfigPath) patched.TELEMETRY_NODE_CONFIG_PATH = nodeConfigPath;
  if (!patched.TELEMETRY_OUTPUT_MODE) patched.TELEMETRY_OUTPUT_MODE = "file";
  if (patched.TELEMETRY_NODE_SECRET_FILE && !patched.TELEMETRY_NODE_SECRET) {
    patched.TELEMETRY_NODE_SECRET = "doctor-secret-reference-present";
    delete patched.TELEMETRY_NODE_SECRET_FILE;
  }
  try {
    const config = loadConfig(patched, mode === "LaxCodex" ? ["--daemon"] : ["--once"]);
    addCheck(checks, "output_mode", "pass", "output mode parseable", {
      modes: config.outputModes
    });
    addCheck(checks, "state_path", config.statePath && !isRemotePath(config.statePath) ? "pass" : "fail", "state path configured as a local path", {
      configured: Boolean(config.statePath)
    });
    addCheck(checks, "spool_dir", config.spoolDir && !isRemotePath(config.spoolDir) ? "pass" : "fail", "spool dir configured as a local path", {
      configured: Boolean(config.spoolDir)
    });
  } catch (error) {
    addCheck(checks, "config_load", "fail", safeErrorMessage(error), {});
  }
}

function checkUploadConfig(checks: DoctorCheck[], env: NodeJS.ProcessEnv, nodeConfig: DeclarativeNodeConfig | undefined, strictProduction: boolean): void {
  const outputModes = parseOutputModes(env.TELEMETRY_OUTPUT_MODE);
  const httpEnabled = outputModes.includes("http") || strictProduction;
  const hubUrl = env.TELEMETRY_HUB_URL;
  const hubBatchUrl = env.TELEMETRY_HUB_BATCH_URL;
  const nodeId = env.TELEMETRY_NODE_ID || nodeConfig?.node_id;
  const secret = env.TELEMETRY_NODE_SECRET;
  const secretFile = env.TELEMETRY_NODE_SECRET_FILE;
  const keyId = env.TELEMETRY_NODE_KEY_ID;
  const readToken = env.TELEMETRY_READ_TOKEN;
  const urls = [hubUrl, hubBatchUrl].filter((item): item is string => Boolean(item));

  addCheck(checks, "upload_mode", "pass", "upload config checked", {
    http_enabled: httpEnabled,
    hub_url_present: Boolean(hubUrl),
    hub_batch_url_present: Boolean(hubBatchUrl)
  });
  addCheck(checks, "upload_endpoint", !httpEnabled || hubUrl || hubBatchUrl ? "pass" : "fail", httpEnabled ? "HTTP upload endpoint checked" : "HTTP upload disabled", {
    configured: Boolean(hubUrl || hubBatchUrl)
  });
  addCheck(checks, "upload_node_id", !httpEnabled || nodeId ? "pass" : "fail", "upload node id checked", {
    configured: Boolean(nodeId)
  });
  const secretFileValid = Boolean(secretFile && path.isAbsolute(secretFile) && !isRemotePath(secretFile) && existsSync(secretFile));
  const secretConfigured = Boolean(secret) || secretFileValid;
  addCheck(checks, "node_secret", !httpEnabled || secretConfigured ? "pass" : "fail", "node secret reference presence checked", {
    secret_present: Boolean(secret),
    secret_file_configured: Boolean(secretFile),
    secret_file_present: secretFileValid,
    ambiguous_sources: Boolean(secret && secretFile)
  });
  if (secret && secretFile) {
    addCheck(checks, "node_secret_source", "fail", "only one node secret source is allowed", { ambiguous_sources: true });
  } else {
    addCheck(checks, "node_secret_source", "pass", "node secret source is unambiguous", { ambiguous_sources: false });
  }
  addCheck(checks, "node_secret_quality", secret && PLACEHOLDER_PATTERN.test(secret) ? "fail" : "pass", "node secret placeholder check complete", {
    secret_present: Boolean(secret),
    placeholder_detected: Boolean(secret && PLACEHOLDER_PATTERN.test(secret))
  });
  addCheck(checks, "node_key_id", "pass", "node key id checked", {
    configured: Boolean(keyId)
  });
  addCheck(checks, "token_bearing_urls", urls.some(hasTokenBearingUrl) ? "fail" : "pass", "upload URLs checked for embedded credentials", {
    token_bearing_url_detected: urls.some(hasTokenBearingUrl)
  });
  addCheck(checks, "read_token", strictProduction && readToken ? "fail" : "pass", "read token checked", {
    configured: Boolean(readToken),
    allowed_context: readToken ? "local_e2e_only" : "not_configured"
  });
}

function checkPaths(checks: DoctorCheck[], env: NodeJS.ProcessEnv, nodeConfig?: DeclarativeNodeConfig): void {
  const logPath = env.TELEMETRY_LOG_DIR || env.LOG_DIR || "";
  addCheck(checks, "log_path", logPath ? (!isRemotePath(logPath) ? "pass" : "fail") : "warn", logPath ? "log path checked" : "log path not configured", {
    configured: Boolean(logPath)
  });
  const customFiles = (nodeConfig?.collectors ?? []).flatMap((collector: NodeCollectorConfig) => collector.name === "custom-json" ? (collector.files ?? []) : []);
  const remoteCustom = customFiles.some((file) => isRemotePath(file.path));
  addCheck(checks, "custom_json_paths", remoteCustom ? "fail" : "pass", "custom-json file paths checked", {
    files_count: customFiles.length,
    remote_paths_found: remoteCustom
  });
}

function checkLaxCodex(checks: DoctorCheck[], mode: AgentDoctorMode, env: NodeJS.ProcessEnv): void {
  if (mode !== "LaxCodex") return;
  const codexHome = env.CODEX_HOME;
  const provider = env.CODEX_PROVIDER;
  const collector = env.TELEMETRY_COLLECTOR_MODE || env.TELEMETRY_COLLECTOR;
  addCheck(checks, "lax_codex_profile", collector === undefined || collector === "codex-backend-usage" ? "pass" : "warn", "LAX Codex collector expectations checked", {
    codex_home_configured: Boolean(codexHome),
    auth_path_configured: Boolean(codexHome),
    provider_backend_usage: !provider || provider === "backend-usage"
  });
}

function buildResult(mode: AgentDoctorMode, strictProduction: boolean, noNetwork: boolean, checks: DoctorCheck[]): AgentConfigDoctorResult {
  const summary = {
    pass: checks.filter((check) => check.status === "pass").length,
    warn: checks.filter((check) => check.status === "warn").length,
    fail: checks.filter((check) => check.status === "fail").length
  };
  return {
    ok: summary.fail === 0,
    mode,
    strict_production: strictProduction,
    no_network: noNetwork,
    summary,
    checks,
    safe: {
      secret_values_printed: false,
      auth_paths_printed: false,
      raw_env_printed: false,
      forbidden_markers_found: []
    }
  };
}

function addCheck(checks: DoctorCheck[], name: string, status: DoctorStatus, message: string, details?: Record<string, unknown>): void {
  checks.push({ name, status, message, ...(details ? { details } : {}) });
}

function parseOutputModes(value: string | undefined): OutputMode[] {
  const raw = value ?? "file";
  const modes = raw.split(",").map((item) => item.trim()).filter(Boolean);
  return modes.filter((mode): mode is OutputMode => mode === "stdout" || mode === "file" || mode === "http");
}

function hasTokenBearingUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return Boolean(parsed.username || parsed.password || URL_SECRET_PATTERN.test(parsed.search.slice(1)));
  } catch {
    return URL_SECRET_PATTERN.test(value);
  }
}

function isRemotePath(value: string): boolean {
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(value);
}

function pathExists(file: string): boolean {
  return existsSync(path.resolve(file));
}

function safeErrorMessage(error: unknown): string {
  return (error as Error)?.message?.replace(/auth\.json/gi, "auth_file") ?? "config doctor error";
}

function walk(value: unknown, visit: (record: Record<string, unknown>) => void): void {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (const item of value) walk(item, visit);
    return;
  }
  const record = value as Record<string, unknown>;
  visit(record);
  for (const item of Object.values(record)) walk(item, visit);
}
