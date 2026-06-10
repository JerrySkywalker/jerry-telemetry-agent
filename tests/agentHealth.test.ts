import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { buildAgentHealthSnapshot } from "../src/health/agentHealth.js";
import { runOnce } from "../src/main.js";
import { fallbackSnapshot, errorSnapshot } from "../src/collectors/codex/normalizer.js";
import { buildEnvelope } from "../src/telemetry/envelope.js";
import { spoolEvent } from "../src/telemetry/spool.js";
import { tempDir, testConfig } from "./helpers.js";

describe("agent health event", () => {
  it("builds a safe healthy payload from the latest usage snapshot", async () => {
    const dir = await tempDir();
    const config = testConfig({ spoolDir: path.join(dir, "spool"), outputModes: ["file", "http"], nodeSecret: "secret-value" });
    const usage = fallbackSnapshot({ status: "ok" }, config, "2026-06-10T00:00:00.000Z");
    usage.limits = [
      { scope: "default", name: "primary" },
      { scope: "additional", name: "secondary" }
    ];

    const health = await buildAgentHealthSnapshot(config, {
      state: { lastSuccessfulSendAt: "2026-06-10T00:01:00.000Z", lastSuccessfulUsageAt: "2026-06-10T00:00:00.000Z" },
      latestUsage: usage
    });

    expect(health).toMatchObject({
      type: "telemetry.agent.health",
      schema_version: 1,
      node: { id: "us-lax-pro-01", hostname: "novix-lax-01", region: "us-lax" },
      status: { ok: true, degraded: false },
      collectors: [
        {
          name: "codex-backend-usage",
          enabled: true,
          last_success_at: "2026-06-10T00:00:00.000Z",
          last_error_code: null,
          latest_payload_status_ok: true,
          latest_limits_count: 2
        }
      ],
      outputs: { file_enabled: true, http_enabled: true, pending_spool_count: 0 },
      security: { node_secret_present: true }
    });
    expect(JSON.stringify(health)).not.toContain("secret-value");
    expect(health.raw_omitted_keys).toContain("tokens");
  });

  it("reports collector errors and spool backlog without leaking raw inputs", async () => {
    const dir = await tempDir();
    const config = testConfig({ spoolDir: path.join(dir, "spool"), nodeSecret: "secret-value" });
    await spoolEvent(config.spoolDir, { event_type: "codex.usage.snapshot" });
    const usage = errorSnapshot(config, "access_token_missing", "missing token", "2026-06-10T00:00:00.000Z", true);

    const health = await buildAgentHealthSnapshot(config, { state: {}, latestUsage: usage });

    expect(health.status).toMatchObject({ ok: false, degraded: true });
    expect(health.collectors[0]).toMatchObject({
      last_error_code: "access_token_missing",
      latest_payload_status_ok: false,
      latest_limits_count: 0
    });
    expect(health.outputs.pending_spool_count).toBe(1);
    expect(health.raw_omitted_keys).toContain("auth_json");
    expect(JSON.stringify(health)).not.toContain("secret-value");
  });

  it("wraps health payload in telemetry.agent.health envelope", async () => {
    const dir = await tempDir();
    const config = testConfig({ spoolDir: path.join(dir, "spool") });
    const health = await buildAgentHealthSnapshot(config, { state: {} });

    expect(buildEnvelope(config, health as unknown as Record<string, unknown>, "2026-06-10T00:00:00.000Z")).toMatchObject({
      event_type: "telemetry.agent.health",
      payload: { type: "telemetry.agent.health" }
    });
  });

  it("runOnce emits health even when usage snapshot is unchanged", async () => {
    const dir = await tempDir();
    const latest = path.join(dir, "latest.json");
    const healthFile = path.join(dir, "agent-health.json");
    await writeFile(latest, JSON.stringify({ captured_at: "2026-06-10T00:00:00.000Z", status: "ok" }));
    await mkdir(path.join(dir, "spool"));

    const baseConfig = testConfig({
      agentHealthEnabled: true,
      collectorMode: "codex-cli-status-fallback",
      outputModes: ["file"],
      codexStatusLatestPath: latest,
      outputFile: path.join(dir, "out.safe.snapshot.json"),
      usageLatestPath: path.join(dir, "latest.safe.snapshot.json"),
      usageLastGoodPath: path.join(dir, "last-good.safe.snapshot.json"),
      agentHealthOutputFile: healthFile,
      statePath: path.join(dir, "state.json"),
      spoolDir: path.join(dir, "spool")
    });

    await runOnce(baseConfig);
    const firstHealth = JSON.parse(await readFile(healthFile, "utf8")) as { observed_at: string };
    await runOnce(baseConfig);
    const secondHealth = JSON.parse(await readFile(healthFile, "utf8")) as { observed_at: string; type: string };

    expect(secondHealth.type).toBe("telemetry.agent.health");
    expect(Date.parse(secondHealth.observed_at)).toBeGreaterThanOrEqual(Date.parse(firstHealth.observed_at));
  });
});
