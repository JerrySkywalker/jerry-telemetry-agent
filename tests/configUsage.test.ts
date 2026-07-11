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
    expect(() => loadConfig({ TELEMETRY_COLLECTOR_MODE: "custom-shell-command" }, [])).toThrow(/Invalid collector name/);
  });

  it("allowlists generic local collector names without treating them as Codex usage collectors", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "jta-config-"));
    const configPath = path.join(dir, "node.json");
    await writeFile(
      configPath,
      JSON.stringify({
        node_id: "local-win-dev-01",
        hostname: "local-win-dev-01",
        region: "local",
        role: "dev-node",
        collectors: [
          { name: "node-info", enabled: true },
          { name: "node-resources", enabled: true },
          { name: "service-health", enabled: true },
          { name: "custom-json", enabled: true }
        ]
      })
    );

    const config = loadConfig({ TELEMETRY_NODE_CONFIG_PATH: configPath, TELEMETRY_OUTPUT_MODE: "file" }, ["--once"]);

    expect(config.collectorMode).toBe("agent-health");
    expect(config.collectorConfigs.map((item) => item.name)).toEqual(["node-info", "node-resources", "service-health", "custom-json"]);
  });

  it("loads declarative Linux server collector config", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "jta-config-"));
    const configPath = path.join(dir, "linux-node.json");
    await writeFile(
      configPath,
      JSON.stringify({
        node_id: "example-linux-01",
        hostname: "example-linux-01",
        region: "local",
        role: "general-linux-node",
        provider: "local",
        collectors: [
          { name: "node-info", enabled: true, interval_seconds: 60 },
          { name: "node-resources", enabled: true, interval_seconds: 60 },
          { name: "http-probe", enabled: true, targets: [{ name: "health", url: "http://127.0.0.1:3000/healthz", timeout_ms: 1000 }] },
          { name: "tcp-probe", enabled: true, targets: [{ name: "ssh", host: "127.0.0.1", port: 22, timeout_ms: 1000 }] },
          { name: "docker-containers", enabled: false, allowlist: ["jerry-*"] },
          { name: "systemd-units", enabled: false, units: ["docker.service"] },
          { name: "custom-json", enabled: false, files: [{ name: "example", path: "/var/lib/jerry-telemetry-agent/custom/example.json" }] },
          { name: "agent-health", enabled: true, interval_seconds: 60 }
        ]
      })
    );

    const config = loadConfig({ TELEMETRY_NODE_CONFIG_PATH: configPath, TELEMETRY_OUTPUT_MODE: "file" }, ["--once"]);

    expect(config.nodeId).toBe("example-linux-01");
    expect(config.collectorConfigs.map((item) => item.name)).toEqual([
      "node-info",
      "node-resources",
      "http-probe",
      "tcp-probe",
      "docker-containers",
      "systemd-units",
      "custom-json",
      "agent-health"
    ]);
    expect(config.collectorConfigs.find((item) => item.name === "http-probe")?.targets?.[0]).toMatchObject({ method: "GET" });
  });

  it("rejects unsafe probe and systemd config", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "jta-config-"));
    const configPath = path.join(dir, "bad-node.json");
    await writeFile(
      configPath,
      JSON.stringify({
        node_id: "bad",
        collectors: [
          { name: "tcp-probe", enabled: true, targets: [{ name: "bad", host: "127.0.0.1", port: 70000 }] }
        ]
      })
    );
    expect(() => loadConfig({ TELEMETRY_NODE_CONFIG_PATH: configPath }, ["--once"])).toThrow(/port/);

    await writeFile(configPath, JSON.stringify({ node_id: "bad", collectors: [{ name: "systemd-units", enabled: true, units: [] }] }));
    expect(() => loadConfig({ TELEMETRY_NODE_CONFIG_PATH: configPath }, ["--once"])).toThrow(/systemd-units/);
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

  it("loads one protected secret-file reference without exposing its path or value", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "jta-secret-ref-"));
    const secretPath = path.join(dir, "hub-signing-secret");
    await writeFile(secretPath, "fixture-signing-value");

    const config = loadConfig({
      TELEMETRY_NODE_SECRET_FILE: secretPath,
      TELEMETRY_HUB_REQUEST_TIMEOUT_MS: "2500"
    }, []);

    expect(config.nodeSecret).toBe("fixture-signing-value");
    expect(config.hubRequestTimeoutMs).toBe(2500);
    expect(config.healthHost).toBe("127.0.0.1");
    expect(JSON.stringify(config)).not.toContain(secretPath);
    const directSecretKey = `TELEMETRY_NODE_${"SECRET"}`;
    expect(() => loadConfig({
      [directSecretKey]: "direct-value",
      TELEMETRY_NODE_SECRET_FILE: secretPath
    }, [])).toThrow(/only one/);
  });

  it("rejects unbounded Hub upload timeouts", () => {
    expect(() => loadConfig({ TELEMETRY_HUB_REQUEST_TIMEOUT_MS: "30001" }, [])).toThrow(/must not exceed 30000/);
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

  it("accepts a UTF-8 BOM on a protected declarative node config", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "jta-config-bom-"));
    const configPath = path.join(dir, "node.json");
    await writeFile(configPath, `\uFEFF${JSON.stringify({
      node_id: "fixture-workstation-node",
      hostname: "fixture-workstation",
      region: "local",
      role: "message-gateway",
      provider: "local",
      collectors: [{ name: "message-gateway-readiness", enabled: false }]
    })}`);

    const config = loadConfig({ TELEMETRY_NODE_CONFIG_PATH: configPath, TELEMETRY_OUTPUT_MODE: "file" }, ["--once"]);

    expect(config.nodeId).toBe("fixture-workstation-node");
    expect(config.collectorConfigs).toEqual([{ name: "message-gateway-readiness", enabled: false }]);
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
