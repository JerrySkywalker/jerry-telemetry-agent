import { describe, expect, it } from "vitest";
import { HostCodexProvider } from "../src/providers/hostCodexProvider.js";
import { testConfig } from "./helpers.js";

describe("HostCodexProvider", () => {
  it("fails clearly when binary is missing", async () => {
    const provider = new HostCodexProvider(testConfig({
      provider: "host-codex",
      hostCodexBin: "/definitely/missing/codex",
      hostCodexHome: "/definitely/missing/home"
    }));
    await expect(provider.collect()).rejects.toThrow(/HOST_CODEX_BIN/);
  });
});
