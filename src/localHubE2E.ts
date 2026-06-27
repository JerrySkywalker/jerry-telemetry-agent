import crypto from "node:crypto";
import net from "node:net";
import { findForbiddenTelemetryMarkers } from "./telemetry/forbiddenMarkers.js";
import { sanitizeErrorForTelemetry } from "./telemetry/sanitize.js";

export interface LocalHubE2ECredentials {
  nodeId: string;
  writeSecret: string;
  readToken: string;
  readTokenSha256: string;
}

export interface LocalHubEnvOptions {
  host: string;
  port: number;
  sqlitePath: string;
  credentials: LocalHubE2ECredentials;
}

export interface ReadbackBodies {
  nodes: unknown;
  summary: unknown;
  services: unknown;
  custom: unknown;
}

export interface ReadbackCheckResult {
  nodeInNodes: boolean;
  nodeInSummary: boolean;
  serviceSeen: boolean;
  customSeen: boolean;
  eventTypes: string[];
}

export function generateLocalHubE2ECredentials(nodeId = "local-e2e-node-01"): LocalHubE2ECredentials {
  const writeSecret = `e2e-write-${crypto.randomBytes(24).toString("hex")}`;
  const readToken = `e2e-read-${crypto.randomBytes(24).toString("hex")}`;
  return {
    nodeId,
    writeSecret,
    readToken,
    readTokenSha256: sha256Hex(readToken)
  };
}

export function sha256Hex(value: string): string {
  return crypto.createHash("sha256").update(value, "utf8").digest("hex");
}

export function buildLocalHubChildEnv(baseEnv: NodeJS.ProcessEnv, options: LocalHubEnvOptions): NodeJS.ProcessEnv {
  return {
    ...safeChildEnv(baseEnv),
    NODE_ENV: "local-e2e",
    HOST: options.host,
    PORT: String(options.port),
    SQLITE_PATH: options.sqlitePath,
    TELEMETRY_NODE_SECRETS: `${options.credentials.nodeId}:${options.credentials.writeSecret}`,
    TELEMETRY_READ_AUTH_ENABLED: "true",
    TELEMETRY_READ_AUTH_ALLOW_LOCALHOST: "false",
    TELEMETRY_READ_TOKEN_NAME: "local-e2e",
    TELEMETRY_READ_TOKEN_SHA256: options.credentials.readTokenSha256,
    TELEMETRY_INGEST_RATE_LIMIT_ENABLED: "false"
  };
}

export function buildAgentChildEnv(baseEnv: NodeJS.ProcessEnv, credentials: LocalHubE2ECredentials, includeReadToken: boolean): NodeJS.ProcessEnv {
  const nodeSecretEnvName = "TELEMETRY_NODE_" + "SECRET";
  const readTokenEnvName = "TELEMETRY_READ_" + "TOKEN";
  return {
    ...safeChildEnv(baseEnv),
    [nodeSecretEnvName]: credentials.writeSecret,
    ...(includeReadToken ? { [readTokenEnvName]: credentials.readToken } : {})
  };
}

export function safeChildEnv(baseEnv: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const output: NodeJS.ProcessEnv = {};
  const allowed = new Set([
    "ALLUSERSPROFILE",
    "APPDATA",
    "ComSpec",
    "HOME",
    "HOMEDRIVE",
    "HOMEPATH",
    "LOCALAPPDATA",
    "NUMBER_OF_PROCESSORS",
    "OS",
    "Path",
    "PATH",
    "PATHEXT",
    "PROCESSOR_ARCHITECTURE",
    "ProgramData",
    "ProgramFiles",
    "ProgramFiles(x86)",
    "PSModulePath",
    "SystemDrive",
    "SystemRoot",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "windir"
  ]);
  for (const [key, value] of Object.entries(baseEnv)) {
    if (value !== undefined && allowed.has(key)) output[key] = value;
  }
  return output;
}

export function localHubBaseUrl(host: string, port: number): string {
  validateLocalHubHost(host);
  validateLocalHubPort(port);
  return `http://${host}:${port}`;
}

export function localHubBatchUrl(host: string, port: number): string {
  return `${localHubBaseUrl(host, port)}/v1/events/batch`;
}

export function validateLocalHubHost(host: string): void {
  if (host !== "127.0.0.1" && host !== "localhost") {
    throw new Error("local Hub E2E must bind to 127.0.0.1 or localhost");
  }
}

export function validateLocalHubPort(port: number): void {
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new Error("HubPort must be an integer from 1 to 65535");
}

export async function findAvailableLocalPort(preferredPort: number): Promise<number> {
  validateLocalHubPort(preferredPort);
  if (await canBind(preferredPort)) return preferredPort;
  return randomLocalPort();
}

export function evaluateHubReadback(nodeId: string, bodies: ReadbackBodies): ReadbackCheckResult {
  const nodesText = JSON.stringify(bodies.nodes);
  const summaryText = JSON.stringify(bodies.summary);
  const servicesText = JSON.stringify(bodies.services);
  const customText = JSON.stringify(bodies.custom);
  const eventTypes = eventTypesFromSummary(nodeId, bodies.summary);
  return {
    nodeInNodes: nodesText.includes(nodeId),
    nodeInSummary: summaryText.includes(nodeId),
    serviceSeen: servicesText.includes(nodeId),
    customSeen: customText.includes(nodeId),
    eventTypes
  };
}

export function assertReadbackComplete(nodeId: string, bodies: ReadbackBodies): ReadbackCheckResult {
  const forbidden = scanLocalHubE2EText(JSON.stringify(bodies));
  if (forbidden.length > 0) throw new Error("Hub readback contains a forbidden marker");
  const result = evaluateHubReadback(nodeId, bodies);
  if (!result.nodeInNodes) throw new Error("Hub /v1/nodes did not include node_id");
  if (!result.nodeInSummary) throw new Error("Hub /v1/summary did not include node_id");
  if (!result.serviceSeen) throw new Error("Hub /v1/services did not include node_id");
  if (!result.customSeen) throw new Error("Hub /v1/custom did not include node_id");
  return result;
}

export function scanLocalHubE2EText(value: string, credentials?: LocalHubE2ECredentials): string[] {
  const markers = [...findForbiddenTelemetryMarkers(value)];
  if (credentials) {
    if (value.includes(credentials.writeSecret)) markers.push("generated_write_secret");
    if (value.includes(credentials.readToken)) markers.push("generated_read_token");
    if (value.includes(credentials.readTokenSha256)) markers.push("generated_read_token_hash");
  }
  return [...new Set(markers)];
}

export function safeE2EError(error: unknown, fallbackCode = "local_hub_agent_e2e_error"): string {
  return sanitizeErrorForTelemetry(error, fallbackCode).message.replace(/\s+/g, "_").slice(0, 120);
}

function eventTypesFromSummary(nodeId: string, summary: unknown): string[] {
  if (!summary || typeof summary !== "object" || Array.isArray(summary)) return [];
  const nodes = (summary as { nodes?: unknown }).nodes;
  if (!Array.isArray(nodes)) return [];
  const node = nodes.find((item) => {
    return item && typeof item === "object" && !Array.isArray(item) && (item as { node_id?: unknown }).node_id === nodeId;
  });
  const eventTypes = node && typeof node === "object" && !Array.isArray(node) ? (node as { event_types?: unknown }).event_types : undefined;
  return Array.isArray(eventTypes) ? eventTypes.filter((item): item is string => typeof item === "string") : [];
}

async function canBind(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.listen(port, "127.0.0.1", () => {
      server.close(() => resolve(true));
    });
  });
}

async function randomLocalPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("failed to allocate local port"));
        return;
      }
      const port = address.port;
      server.close(() => resolve(port));
    });
  });
}
