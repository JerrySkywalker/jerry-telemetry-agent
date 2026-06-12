import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { sanitizeSnapshotPayload } from "../telemetry/sanitize.js";

export async function writeSnapshotFile(file: string, snapshot: unknown): Promise<void> {
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(sanitizeSnapshotPayload(snapshot), null, 2)}\n`, { mode: 0o600 });
}
