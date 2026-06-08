import { describe, expect, it } from "vitest";
import { errorSnapshot, normalizeCodexUsage, summarizeCodexUsage } from "../src/collectors/codex/normalizer.js";
import { testConfig } from "./helpers.js";

describe("Codex usage normalizer", () => {
  const raw = {
    plan_type: "pro",
    rate_limit_reached_type: null,
    rate_limit: { used_percent: 35, limit_window_seconds: 300, reset_at: 1780862400 },
    additional_rate_limits: [{ limit_name: "cloud", metered_feature: "cloud_tasks", used_percent: 80, reset_at: 1780866000 }],
    credits: { has_credits: true, unlimited: false, overage_limit_reached: false, balance: "10.00" },
    spend_control: { reached: false, individual_limit: null },
    email: "do-not-emit@example.com",
    account_id: "acct_123",
    referral_beacon: "hidden",
    promo: "hidden"
  };

  it("maps default rate_limit and reset_at_iso", () => {
    const snapshot = normalizeCodexUsage(raw, testConfig(), "2026-06-08T00:00:00.000Z");
    expect(snapshot.limits[0]).toMatchObject({
      scope: "default",
      name: "default",
      used_percent: 35,
      remaining_percent: 65,
      window: {
        window_seconds: 300,
        reset_at_epoch: 1780862400,
        reset_at_iso: "2026-06-07T20:00:00.000Z"
      }
    });
  });

  it("maps additional_rate_limits", () => {
    const snapshot = normalizeCodexUsage(raw, testConfig());
    expect(snapshot.limits[1]).toMatchObject({
      scope: "additional",
      name: "cloud",
      metered_feature: "cloud_tasks",
      used_percent: 80,
      remaining_percent: 20
    });
  });

  it("omits sensitive raw fields", () => {
    const snapshot = normalizeCodexUsage(raw, testConfig());
    expect(JSON.stringify(snapshot)).not.toContain("do-not-emit");
    expect(JSON.stringify(snapshot)).not.toContain("acct_123");
    expect(snapshot.raw_omitted_keys).toEqual(["account_id", "email", "promo", "referral_beacon"]);
  });

  it("creates error snapshots", () => {
    expect(errorSnapshot(testConfig(), "http_403", "forbidden", "2026-06-08T00:00:00.000Z", true)).toMatchObject({
      status: { ok: false, error_code: "http_403", stale: true },
      limits: []
    });
  });

  it("generates compact summary", () => {
    const summary = summarizeCodexUsage(normalizeCodexUsage(raw, testConfig()), "2026-06-08T00:00:00.000Z");
    expect(summary).toMatchObject({
      ok: true,
      node_id: "us-lax-pro-01",
      plan_type: "pro",
      default_limit: {
        primary: { used_percent: 35, remaining_percent: 65 },
        reset_at_iso: "2026-06-07T20:00:00.000Z"
      },
      additional_limits: [{ name: "cloud" }],
      last_success_at: "2026-06-08T00:00:00.000Z"
    });
  });
});
