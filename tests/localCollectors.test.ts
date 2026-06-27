import { writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { collectCustomJson, collectNodeInfo, collectNodeResources, collectServiceHealth, type LocalCollectorContext } from "../src/collectors/local.js";
import { tempDir } from "./helpers.js";

const context: LocalCollectorContext = {
  mode: "LocalWindows",
  nodeId: "local-win-dev-01",
  hostname: "local-win-dev-01",
  region: "local",
  role: "dev-node",
  provider: "local",
  capturedAt: "2026-06-08T00:00:00.000Z"
};

describe("local collectors", () => {
  it("collects safe node info fields only", () => {
    const payload = collectNodeInfo(context);

    expect(Object.keys(payload).sort()).toEqual([
      "agent_version",
      "arch",
      "hostname",
      "kernel",
      "node_id",
      "os",
      "platform",
      "provider",
      "region",
      "role",
      "uptime_seconds"
    ]);
    expect(payload.node_id).toBe("local-win-dev-01");
  });

  it("collects safe resource fields without inventing unavailable cpu or process metrics", async () => {
    const payload = await collectNodeResources(context);

    expect(payload.cpu_percent).toBeNull();
    expect(payload.process_count).toBeNull();
    expect(payload.memory_total_bytes).toBeTypeOf("number");
    expect(Array.isArray(payload.disks)).toBe(true);
  });

  it("uses deterministic fixture service and custom payloads", async () => {
    const fixtureContext = { ...context, mode: "Fixture" as const };

    await expect(collectServiceHealth(fixtureContext)).resolves.toMatchObject({
      services: [{ name: "fixture-local-service", status: "ok" }]
    });
    await expect(collectCustomJson(fixtureContext)).resolves.toMatchObject({
      source: "fixture",
      safe_declared: true,
      data: { status: "ok", value: 42 }
    });
  });

  it("summarizes arbitrary custom JSON unless it is explicitly marked safe", async () => {
    const dir = await tempDir();
    const unsafeFile = path.join(dir, "custom.json");
    await writeFile(unsafeFile, JSON.stringify({ account_id: "raw", nested: { value: 1 } }));

    const unsafePayload = await collectCustomJson({ ...context, customJsonFile: unsafeFile });
    expect(unsafePayload).toMatchObject({
      source: "file",
      safe_declared: false,
      summary: { top_level_type: "object", object_key_count: 2 }
    });
    expect(JSON.stringify(unsafePayload)).not.toContain("raw");

    const safeFile = path.join(dir, "custom-safe.json");
    await writeFile(safeFile, JSON.stringify({ safe: true, data: { status: "ok", account_id: "raw" } }));
    const safePayload = await collectCustomJson({ ...context, customJsonFile: safeFile });

    expect(safePayload).toMatchObject({
      safe_declared: true,
      data: { status: "ok" }
    });
    expect(JSON.stringify(safePayload)).not.toContain("account_id");
  });
});
