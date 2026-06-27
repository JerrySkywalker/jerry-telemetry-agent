import { describe, expect, it } from "vitest";
import { collectLinuxNodeInfo, parseOsReleaseName } from "../src/collectors/linux/nodeInfo.js";
import { collectLinuxResources, parseDfOutput } from "../src/collectors/linux/resources.js";
import { findForbiddenTelemetryMarkers } from "../src/telemetry/forbiddenMarkers.js";

describe("linux collectors", () => {
  it("parses os-release without user or path leakage", async () => {
    expect(parseOsReleaseName('NAME="Ubuntu"\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n')).toBe("Ubuntu 24.04 LTS");

    const payload = await collectLinuxNodeInfo(
      {
        nodeId: "example-linux-01",
        hostname: "example-linux-01",
        region: "local",
        role: "general-linux-node",
        provider: "local",
        capturedAt: "2026-06-08T00:00:00.000Z"
      },
      { platform: "linux", osReleaseText: 'PRETTY_NAME="Example Linux"\n' }
    );

    expect(payload).toMatchObject({
      node_id: "example-linux-01",
      platform: "linux",
      os: "Example Linux"
    });
    expect(findForbiddenTelemetryMarkers(payload)).toEqual([]);
  });

  it("parses fixed df output into safe disk summaries", () => {
    const disks = parseDfOutput("Filesystem Type 1B-blocks Used Available Use% Mounted on\n/dev/sda1 ext4 1000 250 750 25% /\n");

    expect(disks).toEqual([
      { filesystem_type: "ext4", mount: "/", total_bytes: 1000, free_bytes: 750, used_percent: 25 }
    ]);
  });

  it("keeps unavailable metrics null or unknown", async () => {
    const payload = await collectLinuxResources({ platform: "win32", dfOutput: "" });

    expect(payload.cpu_percent).toBeNull();
    expect(payload.process_count).toBeNull();
    expect(payload.network).toMatchObject({ status: expect.any(String) });
    expect(JSON.stringify(payload)).not.toContain("PATH=");
  });
});
