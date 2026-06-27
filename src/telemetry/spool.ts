import { mkdir, readdir, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import type { TelemetryBatch } from "./envelope.js";
import { assertNoForbiddenTelemetryMarkers } from "./forbiddenMarkers.js";
import { sanitizeSnapshotPayload } from "./sanitize.js";

export interface SpooledEvent {
  path: string;
  event: unknown;
}

export interface SpooledBatch {
  path: string;
  batch: TelemetryBatch;
}

export interface SpoolLimitResult {
  fileCount: number;
  totalBytes: number;
  droppedFiles: number;
}

const BATCH_SUFFIX = ".batch.json";

export async function spoolEvent(spoolDir: string, event: unknown): Promise<string> {
  await mkdir(spoolDir, { recursive: true });
  const file = path.join(spoolDir, `${new Date().toISOString().replace(/[:.]/g, "-")}-${crypto.randomUUID()}.json`);
  await writeFile(file, `${JSON.stringify(sanitizeSnapshotPayload(event))}\n`, { mode: 0o600 });
  return file;
}

export async function spoolBatch(spoolDir: string, batch: TelemetryBatch): Promise<string> {
  await mkdir(spoolDir, { recursive: true });
  const sanitized = sanitizeSnapshotPayload(batch);
  assertTelemetryBatch(sanitized);
  assertNoForbiddenTelemetryMarkers(sanitized);
  const file = path.join(spoolDir, `${new Date().toISOString().replace(/[:.]/g, "-")}-${crypto.randomUUID()}${BATCH_SUFFIX}`);
  await writeFile(file, `${JSON.stringify(sanitized, null, 2)}\n`, { mode: 0o600 });
  return file;
}

export async function listSpooledEvents(spoolDir: string): Promise<SpooledEvent[]> {
  await mkdir(spoolDir, { recursive: true });
  const names = (await readdir(spoolDir)).filter((name) => isEventSpoolName(name)).sort();
  const events: SpooledEvent[] = [];
  for (const name of names) {
    const file = path.join(spoolDir, name);
    events.push({ path: file, event: sanitizeSnapshotPayload(JSON.parse(await readFile(file, "utf8")) as unknown) });
  }
  return events;
}

export async function listSpooledBatchFiles(spoolDir: string): Promise<string[]> {
  await mkdir(spoolDir, { recursive: true });
  return (await readdir(spoolDir))
    .filter((name) => name.endsWith(BATCH_SUFFIX))
    .sort()
    .map((name) => path.join(spoolDir, name));
}

export async function readSpooledBatch(file: string): Promise<TelemetryBatch> {
  const batch = sanitizeSnapshotPayload(JSON.parse(await readFile(file, "utf8")) as unknown);
  assertTelemetryBatch(batch);
  assertNoForbiddenTelemetryMarkers(batch);
  return batch;
}

export async function listSpooledBatches(spoolDir: string): Promise<SpooledBatch[]> {
  const files = await listSpooledBatchFiles(spoolDir);
  const batches: SpooledBatch[] = [];
  for (const file of files) {
    batches.push({ path: file, batch: await readSpooledBatch(file) });
  }
  return batches;
}

export async function removeSpooledEvent(file: string): Promise<void> {
  await unlink(file);
}

export async function quarantineSpooledEvent(file: string): Promise<void> {
  await rename(file, `${file}.bad`);
}

export async function removeSpooledBatch(file: string): Promise<void> {
  await unlink(file);
}

export async function quarantineSpooledBatch(file: string): Promise<void> {
  await rename(file, `${file}.bad`);
}

export async function countSpooledEvents(spoolDir: string): Promise<number> {
  await mkdir(spoolDir, { recursive: true });
  return (await readdir(spoolDir)).filter((name) => isEventSpoolName(name)).length;
}

export async function countSpooledBatches(spoolDir: string): Promise<number> {
  return (await listSpooledBatchFiles(spoolDir)).length;
}

export async function countAllSpooledPayloads(spoolDir: string): Promise<number> {
  const [events, batches] = await Promise.all([countSpooledEvents(spoolDir), countSpooledBatches(spoolDir)]);
  return events + batches;
}

export async function enforceBatchSpoolLimits(
  spoolDir: string,
  limits: { maxFiles?: number; maxBytes?: number }
): Promise<SpoolLimitResult> {
  await mkdir(spoolDir, { recursive: true });
  const maxFiles = positiveOrDefault(limits.maxFiles, 100);
  const maxBytes = positiveOrDefault(limits.maxBytes, 10 * 1024 * 1024);
  let entries = await batchEntries(spoolDir);
  let totalBytes = entries.reduce((sum, item) => sum + item.size, 0);
  let droppedFiles = 0;

  while (entries.length > maxFiles || totalBytes > maxBytes) {
    const [oldest, ...rest] = entries;
    await unlink(oldest.file);
    droppedFiles += 1;
    totalBytes -= oldest.size;
    entries = rest;
  }

  return { fileCount: entries.length, totalBytes, droppedFiles };
}

function isEventSpoolName(name: string): boolean {
  return name.endsWith(".json") && !name.endsWith(BATCH_SUFFIX);
}

function assertTelemetryBatch(value: unknown): asserts value is TelemetryBatch {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new SyntaxError("Invalid telemetry batch spool payload");
  const batch = value as Record<string, unknown>;
  if (batch.schema_version !== "v1" || !Array.isArray(batch.events)) throw new SyntaxError("Invalid telemetry batch spool payload");
  for (const event of batch.events) {
    if (!event || typeof event !== "object" || Array.isArray(event)) throw new SyntaxError("Invalid telemetry batch spool event");
    const item = event as Record<string, unknown>;
    if (item.schema_version !== "v1" || typeof item.event_type !== "string" || typeof item.captured_at !== "string") {
      throw new SyntaxError("Invalid telemetry batch spool event");
    }
    if (!item.source || typeof item.source !== "object" || Array.isArray(item.source)) throw new SyntaxError("Invalid telemetry batch spool event source");
    if (!item.payload || typeof item.payload !== "object" || Array.isArray(item.payload)) throw new SyntaxError("Invalid telemetry batch spool event payload");
  }
}

async function batchEntries(spoolDir: string): Promise<Array<{ file: string; size: number }>> {
  const files = await listSpooledBatchFiles(spoolDir);
  const entries = await Promise.all(files.map(async (file) => ({ file, size: (await stat(file)).size })));
  return entries.sort((a, b) => path.basename(a.file).localeCompare(path.basename(b.file)));
}

function positiveOrDefault(value: number | undefined, fallback: number): number {
  return Number.isFinite(value) && value !== undefined && value > 0 ? value : fallback;
}
