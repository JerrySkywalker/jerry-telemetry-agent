import { writeSnapshotFile } from "./sinks/fileSink.js";
import { buildLocalTelemetryBatch, type LocalBatchOptions } from "./localBatch.js";
import { findForbiddenTelemetryMarkers } from "./telemetry/forbiddenMarkers.js";
import { uploadBatch } from "./telemetry/uploader.js";

export type AgentOnceOutput = "FileOnly" | "Push";

export interface AgentOnceOptions extends LocalBatchOptions {
  output: AgentOnceOutput;
  outFile: string;
  hubUrl?: string;
  writeSecret?: string;
  readToken?: string;
  skipReadback?: boolean;
  keyId?: string;
}

export interface AgentOnceResult {
  node_id: string;
  events_count: number;
  event_types: string[];
  output_file: string;
  forbidden_markers_found: boolean;
  upload: "skipped" | "ok";
  readback: "skipped" | "checked";
  readback_node_seen?: boolean;
}

export async function runAgentOnce(options: AgentOnceOptions): Promise<AgentOnceResult> {
  const batch = await buildLocalTelemetryBatch({
    ...options,
    httpEnabled: options.output === "Push"
  });
  const forbidden = findForbiddenTelemetryMarkers(batch);
  await writeSnapshotFile(options.outFile, batch);

  const result: AgentOnceResult = {
    node_id: options.nodeId,
    events_count: batch.events.length,
    event_types: [...new Set(batch.events.map((event) => event.event_type))],
    output_file: options.outFile,
    forbidden_markers_found: forbidden.length > 0,
    upload: "skipped",
    readback: "skipped"
  };

  if (forbidden.length > 0) {
    throw new Error("Telemetry batch contains a forbidden marker");
  }

  if (options.output === "FileOnly") return result;

  const hubUrl = normalizeHubEventUrl(options.hubUrl);
  const hubBatchUrl = normalizeHubBatchUrl(options.hubUrl);
  if (!options.writeSecret) {
    throw new Error("Push mode requires WriteSecret");
  }

  const uploadResult = await uploadBatch(
    {
      hubUrl,
      hubBatchUrl,
      nodeId: options.nodeId,
      nodeSecret: options.writeSecret,
      nodeKeyId: options.keyId
    },
    batch
  );
  if (findForbiddenTelemetryMarkers(uploadResult.body).length > 0) {
    throw new Error("Hub upload response contains a forbidden marker");
  }
  result.upload = "ok";

  if (options.skipReadback) return result;
  if (!options.readToken) {
    throw new Error("Readback requires ReadToken or SkipReadback");
  }

  result.readback_node_seen = await verifyHubReadback(baseHubUrl(options.hubUrl), options.readToken, options.nodeId);
  result.readback = "checked";
  if (!result.readback_node_seen) {
    throw new Error("Hub readback did not include the pushed node_id");
  }
  return result;
}

export function normalizeHubEventUrl(hubUrl: string | undefined): string {
  if (!hubUrl?.trim()) throw new Error("Push mode requires HubUrl");
  const base = trimTrailingSlash(hubUrl.trim());
  if (base.endsWith("/v1/events/batch")) return base.slice(0, -"/batch".length);
  if (base.endsWith("/v1/events")) return base;
  return `${base}/v1/events`;
}

export function normalizeHubBatchUrl(hubUrl: string | undefined): string {
  if (!hubUrl?.trim()) throw new Error("Push mode requires HubUrl");
  const base = trimTrailingSlash(hubUrl.trim());
  if (base.endsWith("/v1/events/batch")) return base;
  if (base.endsWith("/v1/events")) return `${base}/batch`;
  return `${base}/v1/events/batch`;
}

async function verifyHubReadback(hubUrl: string, readToken: string, nodeId: string): Promise<boolean> {
  const endpoints = ["/v1/nodes", "/v1/summary", "/v1/services", "/v1/custom"];
  let nodeSeen = false;

  for (const endpoint of endpoints) {
    const response = await fetch(`${hubUrl}${endpoint}`, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${readToken}`,
        Accept: "application/json"
      }
    });
    const body = await response.text();
    if (!response.ok) {
      throw new Error(`Hub readback failed for ${endpoint} with HTTP ${response.status}`);
    }
    if (findForbiddenTelemetryMarkers(body).length > 0) {
      throw new Error(`Hub readback for ${endpoint} contains a forbidden marker`);
    }
    if ((endpoint === "/v1/nodes" || endpoint === "/v1/summary") && body.includes(nodeId)) {
      nodeSeen = true;
    }
  }

  return nodeSeen;
}

function baseHubUrl(hubUrl: string | undefined): string {
  if (!hubUrl?.trim()) throw new Error("Push mode requires HubUrl");
  let base = trimTrailingSlash(hubUrl.trim());
  if (base.endsWith("/v1/events/batch")) base = base.slice(0, -"/v1/events/batch".length);
  if (base.endsWith("/v1/events")) base = base.slice(0, -"/v1/events".length);
  return base;
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/g, "");
}
