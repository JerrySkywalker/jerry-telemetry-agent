import path from "node:path";
import { describe, expect, it } from "vitest";
import { readState, updateState, writeState } from "../src/telemetry/state.js";
import { tempDir } from "./helpers.js";

describe("state", () => {
  it("returns empty state when missing", async () => {
    const file = path.join(await tempDir(), "state.json");
    await expect(readState(file)).resolves.toEqual({});
  });

  it("writes and updates state", async () => {
    const file = path.join(await tempDir(), "state.json");
    await writeState(file, { lastPayloadHash: "a" });
    await updateState(file, { lastError: "oops" });
    await expect(readState(file)).resolves.toEqual({ lastPayloadHash: "a", lastError: "oops" });
  });
});
