import { writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { collectCustomJsonFile, normalizeCustomJson } from "../src/collectors/custom/jsonFile.js";
import { tempDir } from "./helpers.js";

describe("custom JSON collector", () => {
  it("accepts valid safe JSON and removes forbidden keys", () => {
    const payload = normalizeCustomJson(
      "example",
      {
        safe: true,
        status: "ok",
        message: "ready",
        tags: ["fixture"],
        safe_values: {
          value: 1,
          secret: "nope",
          nested: { email: "user@example.test", ok: true }
        }
      },
      "2026-06-08T00:00:00.000Z"
    );

    expect(payload).toMatchObject({
      name: "example",
      status: "ok",
      safe_values: { value: 1, nested: { ok: true } }
    });
    expect(JSON.stringify(payload)).not.toContain("user@example");
  });

  it("reports invalid JSON safely", async () => {
    const dir = await tempDir();
    const file = path.join(dir, "bad.json");
    await writeFile(file, "{not-json");

    const payload = await collectCustomJsonFile({ name: "bad", path: file }, "2026-06-08T00:00:00.000Z");

    expect(payload).toMatchObject({
      name: "bad",
      status: "degraded",
      message: "custom json file unavailable or invalid"
    });
  });

  it("reports oversized JSON safely", async () => {
    const dir = await tempDir();
    const file = path.join(dir, "large.json");
    await writeFile(file, JSON.stringify({ safe: true, safe_values: { text: "x".repeat(70 * 1024) } }));

    const payload = await collectCustomJsonFile({ name: "large", path: file }, "2026-06-08T00:00:00.000Z");

    expect(payload).toMatchObject({
      status: "degraded",
      message: "custom json file exceeds size limit"
    });
  });
});
