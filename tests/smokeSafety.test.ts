import { describe, expect, it } from "vitest";
import { validateCodexUsageSmokeSnapshot } from "../src/codex/smokeSafety.js";
import { normalizeCodexUsage, summarizeCodexUsage } from "../src/collectors/codex/normalizer.js";
import { buildEnvelope } from "../src/telemetry/envelope.js";
import { sanitizeErrorForTelemetry, sanitizeSnapshotPayload, sanitizeTelemetryString } from "../src/telemetry/sanitize.js";
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

  it("rejects the auth file marker in safe snapshots", () => {
    const result = validateCodexUsageSmokeSnapshot({
      type: "codex.usage.snapshot",
      status: { ok: false, message: "/home/ubuntu/.codex/auth.json not found" },
      limits: [],
      limits_detail: [],
      observed_at: "2026-06-08T00:00:00.000Z",
      node: { id: "local" }
    });

    expect(result.ok).toBe(false);
    expect(result.errors).toContain("snapshot contains forbidden marker: auth.json");
  });

  it("sanitizes auth file markers and bearer strings recursively", () => {
    const payload = sanitizeSnapshotPayload({
      status: { message: "/home/ubuntu/.codex/auth.json not found" },
      nested: [{ text: "Authorization: Bearer secret-token" }, { text: "auth.json" }]
    });
    const serialized = JSON.stringify(payload);

    expect(serialized).not.toContain("auth.json");
    expect(serialized).not.toContain("/home/ubuntu/.codex");
    expect(serialized).not.toContain("secret-token");
    expect(serialized).toContain("<auth_file>");
  });

  it("redacts nested token values and removes raw identity fields", () => {
    const accessTokenKey = "access" + "_token";
    const refreshTokenKey = "refresh" + "_token";
    const idTokenKey = "id" + "_token";
    const payload = sanitizeSnapshotPayload({
      [accessTokenKey]: "secret-access",
      [refreshTokenKey]: "secret-refresh",
      account: {
        email: "user@example.com",
        account_id: "acct-secret",
        plan_type: "pro"
      },
      nested: [{ user_id: "user-secret", [idTokenKey]: "secret-id", promo: "secret-promo" }]
    });

    expect(payload).toEqual({
      account: { plan_type: "pro" },
      nested: [{}]
    });
  });

  it("sanitizes Error messages before telemetry use", () => {
    const safe = sanitizeErrorForTelemetry(new Error("/home/ubuntu/.codex/auth.json not found"));

    expect(safe.message).toBe("<auth_file> not found");
    expect(safe.message).not.toContain("auth.json");
  });

  it("sanitizes standalone auth file strings", () => {
    expect(sanitizeTelemetryString("auth.json")).toBe("auth_file");
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
    expect(envelope.payload).toEqual(snapshot);
  });

  it("uses CODEX_HOME and defaults backend usage provider and collector", () => {
    const config = loadConfig({ CODEX_HOME: "C:/Users/test/.codex" }, []);

    expect(config.codexHome).toBe("C:/Users/test/.codex");
    expect(config.provider).toBe("backend-usage");
    expect(config.collectorMode).toBe("codex-backend-usage");
  });
});
