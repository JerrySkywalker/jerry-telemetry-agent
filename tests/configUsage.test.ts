import { describe, expect, it } from "vitest";
import { defaultCodexHome, loadConfig } from "../src/config.js";

describe("usage collector config", () => {
  it("defaults to backend usage and keeps tmux fallback disabled", () => {
    const config = loadConfig({}, []);
    expect(config.collectorMode).toBe("codex-backend-usage");
    expect(config.provider).toBe("backend-usage");
    expect(config.intervalSeconds).toBe(300);
    expect(config.agentHealthEnabled).toBe(true);
    expect(config.agentHealthEventType).toBe("telemetry.agent.health");
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

  it("uses explicit CODEX_HOME when provided", () => {
    expect(defaultCodexHome({ CODEX_HOME: "C:\\Users\\jerry\\.codex" }, "win32", "C:\\ignored")).toBe("C:\\Users\\jerry\\.codex");
  });

  it("uses USERPROFILE\\.codex as the Windows default", () => {
    expect(defaultCodexHome({ USERPROFILE: "C:\\Users\\jerry" }, "win32", "C:\\ignored")).toBe("C:\\Users\\jerry\\.codex");
  });
});
