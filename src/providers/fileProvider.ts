import { readFile } from "node:fs/promises";
import type { Config } from "../config.js";
import { redactCodexStatus } from "../codex/redactCodexStatus.js";
import { validateCodexLatest } from "../codex/validateCodexLatest.js";
import type { CodexProvider, ProviderResult } from "./provider.js";

export class FileProvider implements CodexProvider {
  readonly mode = "file" as const;

  constructor(private readonly config: Config) {}

  async collect(): Promise<ProviderResult> {
    const raw = await readFile(this.config.codexStatusLatestPath, "utf8");
    const parsed = JSON.parse(raw) as unknown;
    const payload = redactCodexStatus(parsed);
    validateCodexLatest(payload);
    return {
      payload,
      capturedAt: payload.captured_at as string,
      sourceFile: this.config.codexStatusLatestPath
    };
  }
}
