import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchCodexUsage } from "../src/collectors/codex/usage-client.js";

describe("Codex usage client", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("sends bearer auth with safe default headers", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ ok: true }), { status: 200 }));

    await expect(fetchCodexUsage({ codexUsageEndpoint: "https://chatgpt.com/backend-api/wham/usage" }, "fake-token")).resolves.toEqual({
      ok: true
    });

    const [, init] = fetchMock.mock.calls[0]!;
    expect(init?.headers).toMatchObject({
      Authorization: "Bearer fake-token",
      Accept: "application/json",
      "User-Agent": "jerry-telemetry-agent/0.1 codex-backend-usage"
    });
    expect(init?.signal).toBeInstanceOf(AbortSignal);
  });

  it.each([
    [401, "http_401"],
    [403, "http_403"],
    [404, "http_404"],
    [429, "http_429"],
    [503, "http_5xx"]
  ])("maps HTTP %s to %s", async (status, code) => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("{}", { status }));

    await expect(fetchCodexUsage({ codexUsageEndpoint: "https://chatgpt.com/backend-api/wham/usage" }, "fake-token")).rejects.toMatchObject({
      code,
      diagnostics: { httpStatus: status, endpointFamily: "wham_usage" }
    });
  });

  it("maps fetch failures to network_error without exposing request details", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("socket failed"));
    process.env.CODEX_USAGE_DISABLE_POWERSHELL_FALLBACK = "true";

    try {
      await expect(fetchCodexUsage({ codexUsageEndpoint: "https://chatgpt.com/backend-api/wham/usage" }, "fake-token")).rejects.toMatchObject({
        code: "network_error",
        message: "Codex usage backend request failed",
        diagnostics: { endpointFamily: "wham_usage" }
      });
    } finally {
      delete process.env.CODEX_USAGE_DISABLE_POWERSHELL_FALLBACK;
    }
  });
});
