import path from "node:path";
import { readFile, writeFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import {
  countAllSpooledPayloads,
  countSpooledBatches,
  countSpooledEvents,
  enforceBatchSpoolLimits,
  listSpooledBatches,
  listSpooledEvents,
  quarantineSpooledBatch,
  readSpooledBatch,
  removeSpooledEvent,
  spoolBatch,
  spoolEvent
} from "../src/telemetry/spool.js";
import type { TelemetryBatch } from "../src/telemetry/envelope.js";
import { findForbiddenTelemetryMarkers } from "../src/telemetry/forbiddenMarkers.js";
import { tempDir } from "./helpers.js";

describe("spool", () => {
  it("spools, lists, counts, and removes events", async () => {
    const dir = await tempDir();
    const file = await spoolEvent(dir, { id: 1 });
    expect(await countSpooledEvents(dir)).toBe(1);
    const events = await listSpooledEvents(dir);
    expect(events).toHaveLength(1);
    expect(events[0].event).toEqual({ id: 1 });
    await removeSpooledEvent(file);
    expect(await countSpooledEvents(dir)).toBe(0);
  });

  it("spools batches separately from single events", async () => {
    const dir = await tempDir();
    await spoolEvent(dir, { id: 1 });
    const file = await spoolBatch(dir, batch("node-a"));

    expect(await countSpooledEvents(dir)).toBe(1);
    expect(await countSpooledBatches(dir)).toBe(1);
    expect(await countAllSpooledPayloads(dir)).toBe(2);
    expect(await listSpooledEvents(dir)).toHaveLength(1);
    await expect(readSpooledBatch(file)).resolves.toMatchObject({ schema_version: "v1" });
    await expect(listSpooledBatches(dir)).resolves.toHaveLength(1);
    expect(findForbiddenTelemetryMarkers(await readFile(file, "utf8"))).toEqual([]);
  });

  it("sanitizes forbidden markers in batch spool files", async () => {
    const dir = await tempDir();
    const file = await spoolBatch(dir, batch("auth.json"));
    const text = await readFile(file, "utf8");
    expect(findForbiddenTelemetryMarkers(text)).toEqual([]);
    expect(text).not.toContain("auth.json");
    expect(text).toContain("auth_file");
  });

  it("quarantines invalid batch spool files", async () => {
    const dir = await tempDir();
    const file = path.join(dir, "bad.batch.json");
    await writeFile(file, "{not-json");
    await expect(readSpooledBatch(file)).rejects.toThrow();
    await quarantineSpooledBatch(file);
    expect(await countSpooledBatches(dir)).toBe(0);
    await expect(readFile(`${file}.bad`, "utf8")).resolves.toContain("not-json");
  });

  it("enforces batch spool limits by dropping oldest batches", async () => {
    const dir = await tempDir();
    await spoolBatch(dir, batch("node-a"));
    await spoolBatch(dir, batch("node-a"));

    const result = await enforceBatchSpoolLimits(dir, { maxFiles: 1, maxBytes: 1024 * 1024 });

    expect(result.droppedFiles).toBe(1);
    expect(await countSpooledBatches(dir)).toBe(1);
  });
});

function batch(nodeId: string): TelemetryBatch {
  return {
    schema_version: "v1",
    events: [
      {
        schema_version: "v1",
        event_type: "node.snapshot",
        source: {
          node_id: nodeId,
          hostname: "host-a",
          region: "local",
          collector: "node-info"
        },
        captured_at: "2026-06-27T00:00:00.000Z",
        payload: { node_id: nodeId }
      }
    ]
  };
}
