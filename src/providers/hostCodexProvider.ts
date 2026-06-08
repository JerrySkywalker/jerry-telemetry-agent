import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { Config } from "../config.js";
import { parseCodexStatusPane } from "../codex/parseCodexStatus.js";
import type { CodexProvider, ProviderResult } from "./provider.js";

const execFileAsync = promisify(execFile);

export class HostCodexProvider implements CodexProvider {
  readonly mode = "host-codex" as const;

  constructor(private readonly config: Config) {}

  async collect(): Promise<ProviderResult> {
    await this.assertUsable();
    const session = this.config.codexTmuxSession;
    const env = { ...process.env, CODEX_HOME: this.config.hostCodexHome };

    await execFileAsync("tmux", ["kill-session", "-t", session], { env }).catch(() => undefined);
    await execFileAsync("tmux", ["new-session", "-d", "-s", session, this.config.hostCodexBin], { env, timeout: 10_000 });
    await execFileAsync("tmux", ["send-keys", "-t", session, "/status", "Enter"], { env, timeout: 10_000 });
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    const { stdout } = await execFileAsync("tmux", ["capture-pane", "-p", "-t", session, "-S", "-200"], { env, timeout: 10_000 });
    await execFileAsync("tmux", ["kill-session", "-t", session], { env }).catch(() => undefined);

    const payload = parseCodexStatusPane(stdout);
    return {
      payload,
      capturedAt: payload.captured_at as string
    };
  }

  private async assertUsable(): Promise<void> {
    try {
      await access(this.config.hostCodexBin, constants.R_OK | constants.X_OK);
    } catch {
      throw new Error(`host-codex provider cannot access executable HOST_CODEX_BIN at ${this.config.hostCodexBin}`);
    }
    try {
      await access(this.config.hostCodexHome, constants.R_OK);
    } catch {
      throw new Error(`host-codex provider cannot access HOST_CODEX_HOME at ${this.config.hostCodexHome}`);
    }
  }
}
