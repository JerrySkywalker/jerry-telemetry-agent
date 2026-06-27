import { describe, expect, it } from "vitest";
import { buildLocalTelemetryBatch } from "../src/localBatch.js";
import { findForbiddenTelemetryMarkers } from "../src/telemetry/forbiddenMarkers.js";

describe("local telemetry batch", () => {
  it("builds a v1 fixture batch with generic and agent health event types", async () => {
    const batch = await buildLocalTelemetryBatch({
      mode: "Fixture",
      nodeId: "local-win-dev-01",
      hostname: "local-win-dev-01",
      region: "local",
      role: "dev-node",
      provider: "local",
      capturedAt: "2026-06-08T00:00:00.000Z"
    });

    expect(batch.schema_version).toBe("v1");
    expect(batch.events.map((event) => event.event_type)).toEqual([
      "node.snapshot",
      "node.resources.snapshot",
      "service.health.snapshot",
      "custom.snapshot",
      "telemetry.agent.health"
    ]);
    expect(batch.events.every((event) => event.schema_version === "v1")).toBe(true);
    expect(batch.events.every((event) => event.source.node_id === "local-win-dev-01")).toBe(true);
    expect(findForbiddenTelemetryMarkers(batch)).toEqual([]);
  });

  it("builds a local batch with node and resource snapshots at minimum", async () => {
    const batch = await buildLocalTelemetryBatch({
      mode: "LocalWindows",
      nodeId: "local-win-dev-01",
      region: "local",
      role: "dev-node",
      provider: "local",
      capturedAt: "2026-06-08T00:00:00.000Z",
      includeAgentHealth: false
    });

    const eventTypes = batch.events.map((event) => event.event_type);
    expect(eventTypes).toContain("node.snapshot");
    expect(eventTypes).toContain("node.resources.snapshot");
    expect(JSON.stringify(batch)).not.toContain("PATH=");
    expect(JSON.stringify(batch)).not.toContain("auth.json");
  });
});
