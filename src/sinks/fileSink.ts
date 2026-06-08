import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import type { CodexUsageSnapshot } from "../types/codex-usage.js";

export async function writeSnapshotFile(file: string, snapshot: CodexUsageSnapshot): Promise<void> {
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(snapshot, null, 2)}\n`, { mode: 0o600 });
}
