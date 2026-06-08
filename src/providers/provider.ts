import type { Config } from "../config.js";

export interface ProviderResult {
  payload: Record<string, unknown>;
  capturedAt: string;
  sourceFile?: string;
}

export interface CodexProvider {
  mode: Config["provider"];
  collect(): Promise<ProviderResult>;
}
