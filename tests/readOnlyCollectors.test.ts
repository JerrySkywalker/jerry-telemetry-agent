import { describe, expect, it } from "vitest";
import { collectDockerContainers, parseDockerPsJsonLines, parsePorts } from "../src/collectors/docker/containers.js";
import { collectSystemdUnits, parseSystemctlShow } from "../src/collectors/systemd/units.js";
import { findForbiddenTelemetryMarkers } from "../src/telemetry/forbiddenMarkers.js";

describe("read-only collectors", () => {
  it("parses safe docker ps JSON lines with allowlist filtering", () => {
    const text = [
      JSON.stringify({ Names: "jerry-api", Image: "app:latest", Status: "Up 1 hour (healthy)", State: "running", Ports: "0.0.0.0:8080->80/tcp" }),
      JSON.stringify({ Names: "secret-db", Image: "db:latest", Status: "Up", State: "running", Ports: "" })
    ].join("\n");

    const containers = parseDockerPsJsonLines(text, ["jerry-*"]);
    expect(containers).toHaveLength(1);
    expect(containers[0]).toMatchObject({
      name: "jerry-api",
      health: "healthy",
      ports: [{ host_port: 8080, container_port: 80, protocol: "tcp" }]
    });
    expect(findForbiddenTelemetryMarkers(containers)).toEqual([]);
  });

  it("parses docker ports without IP disclosure", () => {
    expect(parsePorts("0.0.0.0:8443->443/tcp, 80/tcp")).toEqual([
      { host_port: 8443, container_port: 443, protocol: "tcp" },
      { host_port: null, container_port: 80, protocol: "tcp" }
    ]);
  });

  it("returns safe docker unavailable status", async () => {
    const payload = await collectDockerContainers(["unlikely-*"]);
    expect(payload).toHaveProperty("status");
    expect(JSON.stringify(payload)).not.toContain("Error:");
  }, 15_000);

  it("parses systemctl show output without logs or ExecStart", () => {
    const unit = parseSystemctlShow(
      "Id=docker.service\nDescription=Docker Application Container Engine\nLoadState=loaded\nActiveState=active\nSubState=running\nActiveEnterTimestamp=Sat 2026-06-27 00:00:00 UTC\nExecStart=/usr/bin/dockerd\n",
      "docker.service"
    );

    expect(unit).toMatchObject({
      name: "docker.service",
      active_state: "active",
      sub_state: "running",
      load_state: "loaded",
      status: "healthy"
    });
    expect(JSON.stringify(unit)).not.toContain("ExecStart");
  });

  it("returns safe systemd unavailable status", async () => {
    const payload = await collectSystemdUnits(["definitely-missing-test.service"]);
    expect(payload).toHaveProperty("status");
    expect(JSON.stringify(payload)).not.toContain("journal");
  });
});
