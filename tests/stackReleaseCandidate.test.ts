import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

async function read(path: string): Promise<string> {
  return readFile(path, "utf8");
}

describe("stack release candidate scripts", () => {
  it("stack doctor references the required Agent, Hub, and compatibility checks", async () => {
    const content = await read("scripts/stack-doctor-local.ps1");

    for (const expected of [
      "be540993f046ca66d90f44a255e29bb4f8b7c77e",
      "jerry-telemetry-agent",
      "jerry-telemetry-hub",
      "scripts/release-gate-local.ps1",
      "scripts/smoke-local-hub-agent-e2e.ps1",
      "scripts/smoke-production-like-local.ps1",
      "scripts/sqlite-integrity-local.ps1",
      "scripts/sqlite-backup-local.ps1",
      "scripts/sqlite-restore-dry-run-local.ps1",
      "scripts/prune-retention-local.ps1",
      "AllowMissingHub",
      "clean_except_goal_docs"
    ]) {
      expect(content).toContain(expected);
    }

    for (const endpoint of ["/v1/events/batch", "/v1/nodes", "/v1/summary", "/v1/services", "/v1/custom", "/v1/events/recent"]) {
      expect(content).toContain(endpoint);
    }
  });

  it("stack RC gate invokes both release gates, both E2E modes, packaging, and report generation", async () => {
    const content = await read("scripts/stack-release-candidate-local.ps1");

    for (const expected of [
      "stack-doctor-local.ps1",
      "Hub release gate",
      "Agent release gate",
      "release-gate-local.ps1",
      "smoke-local-hub-agent-e2e.ps1",
      "-Mode Once",
      "-Mode Daemon",
      "package-agent-local.ps1",
      "stack-rc-report.json",
      "stack-rc-report.md",
      "stack-rc-manifest.json",
      "Assert-SafeText",
      "sibling_hub_repo_missing",
      "production_mutation = $false"
    ]) {
      expect(content).toContain(expected);
    }
  });

  it("stack contract references required event types and Hub endpoints", async () => {
    const doctor = await read("scripts/stack-doctor-local.ps1");
    const rc = await read("scripts/stack-release-candidate-local.ps1");
    const combined = `${doctor}\n${rc}`;

    for (const eventType of [
      "node.snapshot",
      "node.resources.snapshot",
      "service.health.snapshot",
      "custom.snapshot",
      "telemetry.agent.health",
      "docker.containers.snapshot",
      "systemd.units.snapshot"
    ]) {
      expect(combined).toContain(eventType);
    }

    for (const endpoint of [
      "POST /v1/events/batch",
      "GET /v1/nodes",
      "GET /v1/summary",
      "GET /v1/services",
      "GET /v1/custom",
      "GET /v1/events/recent"
    ]) {
      expect(rc).toContain(endpoint);
    }

    expect(rc).toContain("recent_history");
    expect(rc).toContain("idempotency");
    expect(rc).toContain("read_model");
    expect(rc).toContain("artifact_compatibility");
  });
});

describe("stack release candidate docs", () => {
  it("document the non-deployment boundary and manual authorization requirements", async () => {
    const docs = [
      await read("docs/ops/telemetry-stack-release-candidate.md"),
      await read("docs/ops/telemetry-stack-operator-handoff.md"),
      await read("docs/ops/telemetry-stack-production-authorization.md")
    ].join("\n");

    for (const expected of [
      "not deployment approval",
      "Production deployment remains blocked",
      "Separate manual approval is required",
      "Do not paste real secrets",
      "stack-release-candidate-local.ps1",
      "stack-rc-report.json",
      "stack-rc-manifest.json"
    ]) {
      expect(docs).toContain(expected);
    }
  });

  it("do not include real secret assignments or production mutation commands", async () => {
    const files = [
      "docs/ops/telemetry-stack-release-candidate.md",
      "docs/ops/telemetry-stack-operator-handoff.md",
      "docs/ops/telemetry-stack-production-authorization.md"
    ];

    for (const file of files) {
      const content = await read(file);
      expect(content).not.toMatch(/TELEMETRY_NODE_SECRET\s*=/);
      expect(content).not.toMatch(/TELEMETRY_READ_TOKEN\s*=/);
      expect(content).not.toMatch(/Authorization:\s*\S+/i);
      expect(content).not.toMatch(/Cookie:\s*\S+/i);
      expect(content).not.toMatch(/https?:\/\/[^/\s]+:[^@\s]+@/);
      expect(content).not.toMatch(/\bsystemctl\s+(start|stop|restart|enable|disable)\b/i);
      expect(content).not.toMatch(/\bdocker\s+compose\s+(up|down|restart)\b/i);
      expect(content).not.toMatch(/\b(scp|rsync)\s+\S+/i);
    }
  });
});
