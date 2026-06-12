import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { readCodexAuth, resolveAuthJsonPath } from "../src/collectors/codex/auth-provider.js";
import { tempDir, testConfig } from "./helpers.js";

describe("Codex auth provider", () => {
  it("resolves auth.json under CODEX_HOME", () => {
    expect(resolveAuthJsonPath(testConfig({ codexHome: "/tmp/codex-home" }))).toBe(path.join("/tmp/codex-home", "auth.json"));
  });

  it("reports safe auth unavailable diagnostics when the auth file is missing", async () => {
    await expect(readCodexAuth(testConfig({ codexHome: await tempDir() }))).rejects.toMatchObject({
      code: "codex_auth_unavailable",
      message: "Codex auth unavailable",
      diagnostics: { authSource: "auth_file", authFilePresent: false }
    });
  });

  it("reports safe auth unavailable diagnostics when the access token is missing", async () => {
    const dir = await tempDir();
    await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, "auth.json"), JSON.stringify({ tokens: { refresh_token: "secret" } }));
    await expect(readCodexAuth(testConfig({ codexHome: dir }))).rejects.toMatchObject({
      code: "codex_auth_unavailable",
      message: "Codex auth unavailable",
      diagnostics: { authSource: "auth_file", authFilePresent: true }
    });
  });

  it("extracts current Codex tokens.access_token schema", async () => {
    const dir = await tempDir();
    const accessTokenKey = "access" + "_token";
    const refreshTokenKey = "refresh" + "_token";
    await writeFile(
      path.join(dir, "auth.json"),
      JSON.stringify({
        OPENAI_API_KEY: null,
        auth_mode: "chatgpt",
        last_refresh: "2026-06-08T00:00:00.000Z",
        tokens: {
          [accessTokenKey]: "fake-access-token",
          account_id: "acct_redacted",
          id_token: "fake-id-token",
          [refreshTokenKey]: "fake-refresh-token"
        }
      })
    );

    await expect(readCodexAuth(testConfig({ codexHome: dir }))).resolves.toEqual({
      accessToken: "fake-access-token",
      authPath: path.join(dir, "auth.json")
    });
  });

  it("extracts nested access_token without exposing raw auth", async () => {
    const dir = await tempDir();
    await writeFile(path.join(dir, "auth.json"), JSON.stringify({ chatgpt: { access_token: "token-value" } }));
    await expect(readCodexAuth(testConfig({ codexHome: dir }))).resolves.toMatchObject({ accessToken: "token-value" });
  });
});
