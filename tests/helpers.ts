import os from "node:os";
import path from "node:path";
import { mkdtemp } from "node:fs/promises";
import type { Config } from "../src/config.js";

export async function tempDir(): Promise<string> {
  return mkdtemp(path.join(os.tmpdir(), "jta-"));
}

export function testConfig(overrides: Partial<Config> = {}): Config {
  return {
    mode: "once",
    dryRun: false,
    provider: "file",
    outputModes: ["stdout"],
    intervalSeconds: 600,
    codexHome: "/home/test/.codex",
    codexUsageEndpoint: "https://chatgpt.com/backend-api/wham/usage",
    codexStatusLatestPath: "/input/latest.json",
    hostCodexBin: "/host-bin/codex",
    hostCodexHome: "/host-codex-home",
    codexTmuxSession: "codex-status-agent",
    hubUrl: "http://127.0.0.1:0/telemetry",
    nodeId: "us-lax-pro-01",
    nodeSecret: "test-secret",
    hostname: "novix-lax-01",
    region: "us-lax",
    collector: "codex-status",
    collectorMode: "codex-backend-usage",
    accountLabel: "",
    nodeRole: "",
    platform: "linux",
    outputFile: "/state/codex-usage-latest.safe.snapshot.json",
    usageLatestPath: "/state/codex-usage-latest.safe.snapshot.json",
    usageLastGoodPath: "/state/codex-usage-last-good.safe.snapshot.json",
    statePath: "/state/agent-state.json",
    spoolDir: "/state/spool",
    forceSend: false,
    healthServerEnabled: false,
    healthHost: "127.0.0.1",
    healthPort: 8081,
    ...overrides
  };
}
