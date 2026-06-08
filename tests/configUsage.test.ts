import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

describe("usage collector config", () => {
  it("defaults to backend usage and keeps tmux fallback disabled", () => {
    const config = loadConfig({}, []);
    expect(config.collectorMode).toBe("codex-backend-usage");
    expect(config.intervalSeconds).toBe(300);
  });

  it("enables tmux fallback only when requested", () => {
    expect(loadConfig({ TELEMETRY_ENABLE_TMUX_FALLBACK: "true" }, []).collectorMode).toBe("codex-cli-status-fallback");
    expect(loadConfig({}, ["--collector", "codex-cli-status-fallback"]).collectorMode).toBe("codex-cli-status-fallback");
  });
});
