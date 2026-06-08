import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { readCodexAuth, resolveAuthJsonPath } from "../src/collectors/codex/auth-provider.js";
import { tempDir, testConfig } from "./helpers.js";

describe("Codex auth provider", () => {
  it("resolves auth.json under CODEX_HOME", () => {
    expect(resolveAuthJsonPath(testConfig({ codexHome: "/tmp/codex-home" }))).toBe(path.join("/tmp/codex-home", "auth.json"));
  });

  it("reports auth_json_missing", async () => {
    await expect(readCodexAuth(testConfig({ codexHome: await tempDir() }))).rejects.toMatchObject({ code: "auth_json_missing" });
  });

  it("reports access_token_missing", async () => {
    const dir = await tempDir();
    await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, "auth.json"), JSON.stringify({ tokens: { refresh_token: "secret" } }));
    await expect(readCodexAuth(testConfig({ codexHome: dir }))).rejects.toMatchObject({ code: "access_token_missing" });
  });

  it("extracts nested access_token without exposing raw auth", async () => {
    const dir = await tempDir();
    await writeFile(path.join(dir, "auth.json"), JSON.stringify({ chatgpt: { access_token: "token-value" } }));
    await expect(readCodexAuth(testConfig({ codexHome: dir }))).resolves.toMatchObject({ accessToken: "token-value" });
  });
});
