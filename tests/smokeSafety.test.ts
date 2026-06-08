import { describe, expect, it } from "vitest";
import { validateCodexUsageSmokeSnapshot } from "../src/codex/smokeSafety.js";
import { normalizeCodexUsage, summarizeCodexUsage } from "../src/collectors/codex/normalizer.js";
import { buildEnvelope } from "../src/telemetry/envelope.js";
import { loadConfig } from "../src/config.js";
import { testConfig } from "./helpers.js";

describe("backend usage smoke safety", () => {
  it("accepts normalized snapshots with default and Spark limits", () => {
    const snapshot = normalizeCodexUsage(
      {
        rate_limit: { used_percent: 12 },
        additional_rate_limits: [{ limit_name: "GPT-5.3-Codex-Spark", used_percent: 2 }]
      },
      testConfig(),
      "2026-06-08T00:00:00.000Z"
    );

    expect(validateCodexUsageSmokeSnapshot(snapshot)).toEqual({ ok: true, errors: [] });
  });

  it("rejects forbidden identity and token markers", () => {
    const result = validateCodexUsageSmokeSnapshot({
      type: "codex.usage.snapshot",
      status: { ok: true },
      limits: [],
      observed_at: "2026-06-08T00:00:00.000Z",
      node: { id: "local" },
      account_id: "acct_test"
    });

    expect(result.ok).toBe(false);
    expect(result.errors).toContain("snapshot contains forbidden marker: account_id");
  });

  it("generates summaries from normalized snapshots", () => {
    const summary = summarizeCodexUsage(
      normalizeCodexUsage({ rate_limit: { used_percent: 41 } }, testConfig(), "2026-06-08T00:00:00.000Z"),
      "2026-06-07T23:00:00.000Z"
    );

    expect(summary).toMatchObject({
      ok: true,
      node_id: "us-lax-pro-01",
      default_limit: { primary: { used_percent: 41, remaining_percent: 59 } },
      observed_at: "2026-06-08T00:00:00.000Z",
      last_success_at: "2026-06-07T23:00:00.000Z"
    });
  });

  it("wraps usage snapshots as codex.usage.snapshot events", () => {
    const snapshot = normalizeCodexUsage({ rate_limit: { used_percent: 1 } }, testConfig());
    const envelope = buildEnvelope(testConfig({ collector: "codex-backend-usage" }), snapshot as unknown as Record<string, unknown>);

    expect(envelope.event_type).toBe("codex.usage.snapshot");
    expect(envelope.payload).toBe(snapshot);
  });

  it("uses CODEX_HOME and defaults backend usage provider and collector", () => {
    const config = loadConfig({ CODEX_HOME: "C:/Users/test/.codex" }, []);

    expect(config.codexHome).toBe("C:/Users/test/.codex");
    expect(config.provider).toBe("backend-usage");
    expect(config.collectorMode).toBe("codex-backend-usage");
  });
});
