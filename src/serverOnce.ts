import { readFileSync } from "node:fs";
import { buildServerTelemetryBatch } from "./collectors/serverBatch.js";
import { parseDeclarativeNodeConfig } from "./collectors/registry.js";
import { writeSnapshotFile } from "./sinks/fileSink.js";
import { findForbiddenTelemetryMarkers } from "./telemetry/forbiddenMarkers.js";
import { uploadBatch } from "./telemetry/uploader.js";
import { normalizeHubBatchUrl, normalizeHubEventUrl } from "./localOnce.js";

export type ServerOnceOutput = "FileOnly" | "Push";

export interface ServerOnceOptions {
  configPath: string;
  output: ServerOnceOutput;
  outFile: string;
  hubUrl?: string;
  writeSecret?: string;
  keyId?: string;
}

export interface ServerOnceResult {
  node_id: string;
  events_count: number;
  event_types: string[];
  output_file: string;
  forbidden_markers_found: boolean;
  upload: "skipped" | "ok";
}

export async function runServerOnce(options: ServerOnceOptions): Promise<ServerOnceResult> {
  const config = parseDeclarativeNodeConfig(JSON.parse(readFileSync(options.configPath, "utf8")) as unknown);
  const batch = await buildServerTelemetryBatch(config, { httpEnabled: options.output === "Push" });
  const forbidden = findForbiddenTelemetryMarkers(batch);
  await writeSnapshotFile(options.outFile, batch);

  const result: ServerOnceResult = {
    node_id: config.node_id ?? "unknown",
    events_count: batch.events.length,
    event_types: [...new Set(batch.events.map((event) => event.event_type))],
    output_file: options.outFile,
    forbidden_markers_found: forbidden.length > 0,
    upload: "skipped"
  };

  if (forbidden.length > 0) {
    throw new Error("Server telemetry batch contains a forbidden marker");
  }
  if (options.output === "FileOnly") return result;
  if (!options.writeSecret) throw new Error("Push mode requires WriteSecret");

  await uploadBatch(
    {
      hubUrl: normalizeHubEventUrl(options.hubUrl),
      hubBatchUrl: normalizeHubBatchUrl(options.hubUrl),
      nodeId: config.node_id ?? "unknown",
      nodeSecret: options.writeSecret,
      nodeKeyId: options.keyId
    },
    batch
  );
  result.upload = "ok";
  return result;
}
