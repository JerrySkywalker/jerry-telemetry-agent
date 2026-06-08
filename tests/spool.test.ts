import { describe, expect, it } from "vitest";
import { countSpooledEvents, listSpooledEvents, removeSpooledEvent, spoolEvent } from "../src/telemetry/spool.js";
import { tempDir } from "./helpers.js";

describe("spool", () => {
  it("spools, lists, counts, and removes events", async () => {
    const dir = await tempDir();
    const file = await spoolEvent(dir, { id: 1 });
    expect(await countSpooledEvents(dir)).toBe(1);
    const events = await listSpooledEvents(dir);
    expect(events).toHaveLength(1);
    expect(events[0].event).toEqual({ id: 1 });
    await removeSpooledEvent(file);
    expect(await countSpooledEvents(dir)).toBe(0);
  });
});
