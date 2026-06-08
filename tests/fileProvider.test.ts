import path from "node:path";
import { writeFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { FileProvider } from "../src/providers/fileProvider.js";
import { tempDir, testConfig } from "./helpers.js";

describe("FileProvider", () => {
  it("reads, redacts, and validates latest JSON", async () => {
    const dir = await tempDir();
    const file = path.join(dir, "latest.json");
    await writeFile(file, JSON.stringify({
      captured_at: "2026-06-08T00:00:00.000Z",
      status: "ok",
      account_id: "acct_private",
      session_id: "sess_private"
    }));

    const result = await new FileProvider(testConfig({ codexStatusLatestPath: file })).collect();
    expect(result.payload.account_id).toBe("[REDACTED]");
    expect(result.payload.session_id).toBe("[REDACTED]");
    expect(result.sourceFile).toBe(file);
  });
});
