import type { Config } from "../config.js";
import { signTelemetryBody } from "./hmac.js";

export interface TelemetryUploadConfig {
  hubUrl: string;
  hubBatchUrl?: string;
  nodeId: string;
  nodeSecret: string;
  nodeKeyId?: string;
  timeoutMs?: number;
}

export interface UploadResult {
  status: number;
  ok: boolean;
  body: string;
}

export async function uploadEvent(config: Pick<Config, "hubUrl" | "nodeId" | "nodeSecret" | "nodeKeyId" | "hubRequestTimeoutMs">, event: unknown): Promise<UploadResult> {
  return uploadSignedJson(config.hubUrl, config, event, config.hubRequestTimeoutMs);
}

export async function uploadBatch(config: TelemetryUploadConfig, batch: unknown): Promise<UploadResult> {
  return uploadSignedJson(resolveBatchHubUrl(config), config, batch, config.timeoutMs);
}

export function resolveBatchHubUrl(config: Pick<TelemetryUploadConfig, "hubUrl" | "hubBatchUrl">): string {
  const explicit = config.hubBatchUrl?.trim();
  if (explicit) return explicit;

  const eventUrl = config.hubUrl.trim();
  if (eventUrl.endsWith("/v1/events")) {
    return `${eventUrl.slice(0, -"/v1/events".length)}/v1/events/batch`;
  }

  throw new Error("Missing TELEMETRY_HUB_BATCH_URL; TELEMETRY_HUB_URL must end with /v1/events to derive the batch endpoint");
}

async function uploadSignedJson(url: string, config: Pick<TelemetryUploadConfig, "nodeId" | "nodeSecret" | "nodeKeyId">, payload: unknown, timeoutMs = 5000): Promise<UploadResult> {
  const rawBody = JSON.stringify(payload);
  const signedHeaders = signTelemetryBody(config.nodeId, config.nodeSecret, rawBody);
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...signedHeaders
  };
  if (config.nodeKeyId) {
    headers["X-Telemetry-Key-Id"] = config.nodeKeyId;
  }

  const response = await fetch(url, {
    method: "POST",
    headers,
    body: rawBody,
    signal: AbortSignal.timeout(timeoutMs)
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`Telemetry upload failed with HTTP ${response.status}`);
  }
  return { status: response.status, ok: response.ok, body };
}
