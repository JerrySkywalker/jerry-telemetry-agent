import { mkdir, readdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

export interface SpooledEvent {
  path: string;
  event: unknown;
}

export async function spoolEvent(spoolDir: string, event: unknown): Promise<string> {
  await mkdir(spoolDir, { recursive: true });
  const file = path.join(spoolDir, `${new Date().toISOString().replace(/[:.]/g, "-")}-${crypto.randomUUID()}.json`);
  await writeFile(file, `${JSON.stringify(event)}\n`, { mode: 0o600 });
  return file;
}

export async function listSpooledEvents(spoolDir: string): Promise<SpooledEvent[]> {
  await mkdir(spoolDir, { recursive: true });
  const names = (await readdir(spoolDir)).filter((name) => name.endsWith(".json")).sort();
  const events: SpooledEvent[] = [];
  for (const name of names) {
    const file = path.join(spoolDir, name);
    events.push({ path: file, event: JSON.parse(await readFile(file, "utf8")) as unknown });
  }
  return events;
}

export async function removeSpooledEvent(file: string): Promise<void> {
  await unlink(file);
}

export async function quarantineSpooledEvent(file: string): Promise<void> {
  await rename(file, `${file}.bad`);
}

export async function countSpooledEvents(spoolDir: string): Promise<number> {
  await mkdir(spoolDir, { recursive: true });
  return (await readdir(spoolDir)).filter((name) => name.endsWith(".json")).length;
}
