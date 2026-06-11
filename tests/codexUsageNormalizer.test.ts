import { describe, expect, it } from "vitest";
import { errorSnapshot, normalizeCodexUsage, summarizeCodexUsage } from "../src/collectors/codex/normalizer.js";
import { inspectCodexUsageShape } from "../src/collectors/codex/shape-inspection.js";
import { testConfig } from "./helpers.js";

describe("Codex usage normalizer", () => {
  const raw = {
    plan_type: "pro",
    rate_limit_reached_type: null,
    rate_limit: { used_percent: 35, limit_window_seconds: 300, reset_at: 1780862400 },
    additional_rate_limits: [{ limit_name: "GPT-5.3-Codex-Spark", metered_feature: "cloud_tasks", used_percent: 80, reset_at: 1780866000 }],
    credits: { has_credits: true, unlimited: false, overage_limit_reached: false, balance: "10.00" },
    spend_control: { reached: false, individual_limit: null },
    email: "do-not-emit@example.com",
    account_id: "acct_123",
    referral_beacon: "hidden",
    promo: "hidden"
  };

  it("maps default rate_limit and reset_at_iso", () => {
    const snapshot = normalizeCodexUsage(raw, testConfig(), "2026-06-08T00:00:00.000Z");
    expect(snapshot.limits_count).toBe(2);
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
    expect(snapshot.limits_detail[0]).toMatchObject({
      key: "default:default",
      label: "default",
      source: "default",
      status: "active",
      used_percent: 35,
      remaining_percent: 65,
      reset_at_iso: "2026-06-07T20:00:00.000Z",
      reset_in_seconds: 0,
      reset_source: "backend_absolute",
      completeness: "partial"
    });
  });

  it("maps additional GPT-5.3-Codex-Spark rate limit", () => {
    const snapshot = normalizeCodexUsage(raw, testConfig());
    expect(snapshot.limits[1]).toMatchObject({
      scope: "additional",
      name: "GPT-5.3-Codex-Spark",
      metered_feature: "cloud_tasks",
      used_percent: 80,
      remaining_percent: 20
    });
    expect(snapshot.limits_detail[1]).toMatchObject({
      label: "GPT-5.3-Codex-Spark",
      source: "additional",
      status: "active",
      metered_feature: "cloud_tasks",
      used_percent: 80,
      remaining_percent: 20
    });
  });

  it("preserves backend-like absolute usage and reset fields in limits_detail", () => {
    const snapshot = normalizeCodexUsage(
      {
        rate_limit: {
          display_name: "Default",
          total: 1000,
          consumed: 125,
          available: 875,
          unit: "messages",
          reset_at_iso: "2026-06-08T04:00:00.000Z",
          quota_window_seconds: 86400
        }
      },
      testConfig(),
      "2026-06-08T00:00:00.000Z"
    );

    expect(snapshot.limits_detail[0]).toMatchObject({
      label: "Default",
      total: 1000,
      used: 125,
      remaining: 875,
      unit: "messages",
      reset_at_iso: "2026-06-08T04:00:00.000Z",
      reset_in_seconds: 14400,
      window_seconds: 86400,
      reset_source: "backend_absolute",
      completeness: "full"
    });
  });

  it("normalizes percent fractions and derives reset_at_iso from relative reset seconds", () => {
    const snapshot = normalizeCodexUsage(
      {
        rate_limit: {
          usage_percent: 0.25,
          percent_remaining: 0.75,
          reset_after_seconds: 3600,
          period_seconds: 7200
        }
      },
      testConfig(),
      "2026-06-08T00:00:00.000Z"
    );

    expect(snapshot.limits_detail[0]).toMatchObject({
      used_percent: 25,
      remaining_percent: 75,
      reset_at_iso: "2026-06-08T01:00:00.000Z",
      reset_in_seconds: 3600,
      window_seconds: 7200,
      reset_source: "derived_from_observed_at"
    });
  });

  it("prefers backend limits array when present and preserves safe source values", () => {
    const snapshot = normalizeCodexUsage(
      {
        rate_limit: { used_percent: 99 },
        limits: [
          {
            source: "default",
            label: "Default",
            total: 100,
            used: 25,
            remaining: 75,
            reset_at: "2026-06-08T02:00:00.000Z"
          },
          {
            source: "credit",
            display_name: "Credit grant",
            credits_remaining: 5,
            unit: "credits"
          }
        ]
      },
      testConfig(),
      "2026-06-08T00:00:00.000Z"
    );

    expect(snapshot.limits).toHaveLength(2);
    expect(snapshot.limits_detail).toMatchObject([
      {
        key: "default:Default",
        label: "Default",
        source: "default",
        total: 100,
        used: 25,
        remaining: 75,
        reset_at_iso: "2026-06-08T02:00:00.000Z",
        reset_in_seconds: 7200,
        completeness: "full"
      },
      {
        key: "credit:Credit grant",
        label: "Credit grant",
        source: "credit",
        remaining: 5,
        unit: "credits",
        status: "active",
        completeness: "partial"
      }
    ]);
  });

  it("keeps relative reset seconds without deriving reset_at_iso from invalid observed_at", () => {
    const snapshot = normalizeCodexUsage({ rate_limit: { reset_after_seconds: 300 } }, testConfig(), "not-a-date");

    expect(snapshot.limits_detail[0]).toMatchObject({
      reset_at_iso: null,
      reset_in_seconds: 300,
      reset_source: "backend_relative",
      completeness: "partial"
    });
  });

  it("marks missing detail fields as not reported without fabricating usage", () => {
    const snapshot = normalizeCodexUsage({ rate_limit: { name: "default" } }, testConfig(), "2026-06-08T00:00:00.000Z");
    expect(snapshot.limits_detail[0]).toMatchObject({
      total: null,
      used: null,
      remaining: null,
      used_percent: null,
      remaining_percent: null,
      reset_at_iso: null,
      reset_in_seconds: null,
      window_seconds: null,
      reset_source: "not_reported",
      completeness: "not_reported"
    });
  });

  it("omits sensitive raw fields", () => {
    const snapshot = normalizeCodexUsage(raw, testConfig());
    expect(JSON.stringify(snapshot)).not.toContain("do-not-emit");
    expect(JSON.stringify(snapshot)).not.toContain("acct_123");
    expect(JSON.stringify(snapshot)).not.toContain("account_id");
    expect(JSON.stringify(snapshot)).not.toContain("email");
    const tokenSnapshot = JSON.stringify(normalizeCodexUsage({ ...raw, access_token: "hidden", refresh_token: "hidden", id_token: "hidden" }, testConfig()));
    expect(tokenSnapshot).not.toContain("access_token");
    expect(tokenSnapshot).not.toContain("refresh_token");
    expect(tokenSnapshot).not.toContain("id_token");
    expect(JSON.stringify(snapshot)).not.toContain("referral_beacon");
    expect(JSON.stringify(snapshot)).not.toContain("promo");
    expect(snapshot.raw_omitted_keys).toEqual(["sensitive_raw_fields"]);
  });

  it("does not pass through unknown spend control objects", () => {
    const snapshot = normalizeCodexUsage(
      {
        rate_limit: { name: "default" },
        spend_control: {
          reached: false,
          individual_limit: { account_id: "acct_secret", nested: true }
        }
      },
      testConfig()
    );

    expect(snapshot.spend_control).toEqual({ reached: false, individual_limit: null });
    expect(JSON.stringify(snapshot)).not.toContain("acct_secret");
    expect(JSON.stringify(snapshot)).not.toContain("account_id");
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
      limits_count: 2,
      limits_detail: [{ label: "default" }, { label: "GPT-5.3-Codex-Spark" }],
      default_limit_detail: { label: "default" },
      spark_limit_detail: { label: "GPT-5.3-Codex-Spark" },
      additional_limits: [{ name: "GPT-5.3-Codex-Spark" }],
      last_success_at: "2026-06-08T00:00:00.000Z"
    });
  });

  it("inspects backend response shape without exposing values", () => {
    const fields = inspectCodexUsageShape({
      rate_limit: { used_percent: 42, reset_after_seconds: 1800 },
      additional_rate_limits: [{ limit_name: "GPT-5.3-Codex-Spark", remaining: 10 }]
    });

    expect(fields).toContainEqual({ path: "payload.limits[].used_percent", present: true, type: "number" });
    expect(fields).toContainEqual({ path: "payload.limits[].reset_after_seconds", present: true, type: "number" });
    expect(fields).toContainEqual({ path: "payload.limits[].remaining", present: true, type: "number" });
    expect(JSON.stringify(fields)).not.toContain("GPT-5.3-Codex-Spark");
    expect(JSON.stringify(fields)).not.toContain("42");
  });
});
