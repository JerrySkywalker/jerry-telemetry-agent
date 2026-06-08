import type { Config } from "../config.js";
import { signTelemetryBody } from "./hmac.js";

export interface UploadResult {
  status: number;
  ok: boolean;
  body: string;
}

export async function uploadEvent(config: Config, event: unknown): Promise<UploadResult> {
  const rawBody = JSON.stringify(event);
  const headers = signTelemetryBody(config.nodeId, config.nodeSecret, rawBody);
  const response = await fetch(config.hubUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...headers
    },
    body: rawBody
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`Telemetry upload failed with HTTP ${response.status}`);
  }
  return { status: response.status, ok: response.ok, body };
}
