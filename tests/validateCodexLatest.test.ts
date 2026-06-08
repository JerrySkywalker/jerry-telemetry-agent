import { describe, expect, it } from "vitest";
import { redactCodexStatus } from "../src/codex/redactCodexStatus.js";
import { validateCodexLatest } from "../src/codex/validateCodexLatest.js";

describe("validateCodexLatest", () => {
  it("accepts valid redacted payload", () => {
    expect(() => validateCodexLatest({
      captured_at: "2026-06-08T00:00:00.000Z",
      status: "ok",
      account_id: "[REDACTED]",
      session_id: "[REDACTED]"
    })).not.toThrow();
  });

  it("rejects unredacted account and session fields", () => {
    expect(() => validateCodexLatest({
      captured_at: "2026-06-08T00:00:00.000Z",
      status: "ok",
      account_id: "acct_123"
    })).toThrow(/unredacted/);
  });

  it("redacts sensitive fields recursively", () => {
    const payload = redactCodexStatus({
      captured_at: "2026-06-08T00:00:00.000Z",
      status: "ok",
      nested: { session: "sess_123" }
    });
    expect(payload.nested).toEqual({ session: "[REDACTED]" });
  });
});
