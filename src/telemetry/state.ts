import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

export interface AgentState {
  lastPayloadCapturedAt?: string;
  lastPayloadHash?: string;
  lastSourceFile?: string;
  lastSuccessfulSendAt?: string;
  lastSuccessfulUsageAt?: string;
  lastHealthEventAt?: string;
  lastSuccessfulHealthSendAt?: string;
  lastHttpErrorAt?: string;
  lastError?: string;
}

export async function readState(statePath: string): Promise<AgentState> {
  try {
    return JSON.parse(await readFile(statePath, "utf8")) as AgentState;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw error;
  }
}

export async function writeState(statePath: string, state: AgentState): Promise<void> {
  await mkdir(path.dirname(statePath), { recursive: true });
  await writeFile(statePath, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
}

export async function updateState(statePath: string, patch: Partial<AgentState>): Promise<AgentState> {
  const current = await readState(statePath);
  const next = { ...current, ...patch };
  await writeState(statePath, next);
  return next;
}
