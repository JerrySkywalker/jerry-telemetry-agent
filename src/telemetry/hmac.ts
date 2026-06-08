import crypto from "node:crypto";

export interface HmacHeaders {
  "X-Telemetry-Node": string;
  "X-Telemetry-Timestamp": string;
  "X-Telemetry-Nonce": string;
  "X-Telemetry-Signature": string;
}

export function signTelemetryBody(nodeId: string, secret: string, rawBody: string, timestamp = new Date().toISOString(), nonce: string = crypto.randomUUID()): HmacHeaders {
  const payloadToSign = `${timestamp}.${nonce}.${rawBody}`;
  const signature = crypto.createHmac("sha256", secret).update(payloadToSign).digest("hex");
  return {
    "X-Telemetry-Node": nodeId,
    "X-Telemetry-Timestamp": timestamp,
    "X-Telemetry-Nonce": nonce,
    "X-Telemetry-Signature": signature
  };
}
