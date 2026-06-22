import { describe, expect, it } from "vitest";
import { mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assertUploadConfig } from "../src/config.js";
import { defaultCodexHome, loadConfig } from "../src/config.js";

describe("usage collector config", () => {
  it("defaults to backend usage and keeps tmux fallback disabled", () => {
    const config = loadConfig({}, []);
    expect(config.collectorMode).toBe("codex-backend-usage");
    expect(config.provider).toBe("backend-usage");
    expect(config.intervalSeconds).toBe(300);
    expect(config.agentHealthEnabled).toBe(true);
    expect(config.agentHealthEventType).toBe("telemetry.agent.health");
    expect(config.collectorConfigs).toEqual([
      { name: "codex-backend-usage", enabled: true, interval_seconds: 300 },
      { name: "agent-health", enabled: true, interval_seconds: 300 }
    ]);
  });

  it("keeps once health opt-in unless requested", () => {
    expect(loadConfig({}, ["--once"]).agentHealthEnabled).toBe(false);
    expect(loadConfig({}, ["--once", "--health"]).agentHealthEnabled).toBe(true);
    expect(loadConfig({ TELEMETRY_AGENT_HEALTH_ENABLED: "true" }, ["--once"]).agentHealthEnabled).toBe(true);
  });

  it("enables tmux fallback only when requested", () => {
    expect(loadConfig({ TELEMETRY_ENABLE_TMUX_FALLBACK: "true" }, []).collectorMode).toBe("codex-cli-status-fallback");
    expect(loadConfig({}, ["--collector", "codex-cli-status-fallback"]).collectorMode).toBe("codex-cli-status-fallback");
  });

  it("fails closed for unknown collector names", () => {
    expect(() => loadConfig({ TELEMETRY_COLLECTOR_MODE: "shell" }, [])).toThrow(/Invalid collector name/);
    expect(() => loadConfig({}, ["--collector", "shell"])).toThrow(/Invalid collector name/);
  });

  it("keeps env-only LAX backend usage compatible", () => {
    const config = loadConfig(
      {
        TELEMETRY_NODE_ID: "us-lax-pro-01",
        TELEMETRY_HOSTNAME: "novix-lax-01",
        TELEMETRY_REGION: "us-lax",
        TELEMETRY_OUTPUT_MODE: "file,http",
        TELEMETRY_COLLECTOR_MODE: "codex-backend-usage"
      },
      []
    );
    expect(config.nodeId).toBe("us-lax-pro-01");
    expect(config.hostname).toBe("novix-lax-01");
    expect(config.region).toBe("us-lax");
    expect(config.outputModes).toEqual(["file", "http"]);
    expect(config.collectorMode).toBe("codex-backend-usage");
  });

  it("fails before HTTP upload when upload config is missing", () => {
    const config = loadConfig({ TELEMETRY_OUTPUT_MODE: "file,http", TELEMETRY_NODE_ID: "us-lax-pro-01" }, []);
    expect(() => assertUploadConfig(config)).toThrow(/TELEMETRY_HUB_URL, TELEMETRY_NODE_SECRET/);
  });

  it("loads declarative per-node config while preserving env overrides", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "jta-config-"));
    const configPath = path.join(dir, "node.json");
    await writeFile(
      configPath,
      JSON.stringify({
        node_id: "us-lax-pro-01",
        hostname: "novix-lax-01",
        region: "us-lax",
        role: "codex-node",
        collectors: [
          { name: "codex-backend-usage", enabled: true, interval_seconds: 300 },
          { name: "agent-health", enabled: true, interval_seconds: 300 }
        ]
      })
    );

    const config = loadConfig({ TELEMETRY_NODE_CONFIG_PATH: configPath, TELEMETRY_NODE_ID: "override-node" }, []);

    expect(config.nodeId).toBe("override-node");
    expect(config.hostname).toBe("novix-lax-01");
    expect(config.region).toBe("us-lax");
    expect(config.nodeRole).toBe("codex-node");
    expect(config.collectorMode).toBe("codex-backend-usage");
    expect(config.collectorConfigs).toEqual([
      { name: "codex-backend-usage", enabled: true, interval_seconds: 300 },
      { name: "agent-health", enabled: true, interval_seconds: 300 }
    ]);
  });

  it("loads an agent-health-only non-LAX node config without selecting Codex usage", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "jta-config-"));
    const configPath = path.join(dir, "node.json");
    await writeFile(
      configPath,
      JSON.stringify({
        node_id: "example-node-01",
        hostname: "example-node-01",
        region: "example-region",
        role: "general-node",
        collectors: [
          { name: "agent-health", enabled: true, interval_seconds: 300 }
        ]
      })
    );

    const config = loadConfig({ TELEMETRY_NODE_CONFIG_PATH: configPath, TELEMETRY_OUTPUT_MODE: "file" }, ["--once"]);

    expect(config.nodeId).toBe("example-node-01");
    expect(config.hostname).toBe("example-node-01");
    expect(config.region).toBe("example-region");
    expect(config.nodeRole).toBe("general-node");
    expect(config.collectorMode).toBe("agent-health");
    expect(config.collector).toBe("agent-health");
    expect(config.collectorConfigs).toEqual([
      { name: "agent-health", enabled: true, interval_seconds: 300 }
    ]);
  });

  it("uses explicit CODEX_HOME when provided", () => {
    expect(defaultCodexHome({ CODEX_HOME: "C:\\Users\\jerry\\.codex" }, "win32", "C:\\ignored")).toBe("C:\\Users\\jerry\\.codex");
  });

  it("uses USERPROFILE\\.codex as the Windows default", () => {
    expect(defaultCodexHome({ USERPROFILE: "C:\\Users\\jerry" }, "win32", "C:\\ignored")).toBe("C:\\Users\\jerry\\.codex");
  });
});
