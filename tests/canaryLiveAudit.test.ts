import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

async function read(path: string): Promise<string> {
  return readFile(path, "utf8");
}

function expectNoMutatingCommands(content: string): void {
  expect(content).not.toMatch(/(^|\n)\s*systemctl\s+(start|stop|restart|enable|disable|edit)\b/i);
  expect(content).not.toMatch(/(^|\n)\s*docker\s+(update|stop|start|restart|rm|run|volume\s+rm)\b/i);
  expect(content).not.toMatch(/(^|\n)\s*docker\s+compose\s+(up|down|restart)\b/i);
  expect(content).not.toMatch(/\b(scp|rsync)\s+\S+/i);
}

describe("canary live audit tooling", () => {
  it("live audit script exists and implements read-only canary checks", async () => {
    const content = await read("scripts/canary-live-audit-readonly.ps1");

    for (const expected of [
      "canary-live-audit-summary.md",
      "canary-live-audit-summary.json",
      "hub-live-audit.md",
      "tunnel-live-audit.md",
      "agent-live-audit.md",
      "sample-table.md",
      "marker-scan-report.json",
      "canary-live-audit-checklist.md",
      "systemctl show",
      "docker inspect",
      "docker logs",
      "127.0.0.1:13080",
      "/v1/events/recent",
      "readback_token_printed",
      "raw_logs_printed",
      "production_mutation=false",
      "docker_runtime_mutation=false",
      "service_timer_mutation=false",
      "tunnel_mutation=false"
    ]) {
      expect(content).toContain(expected);
    }

    expect(content).toMatch(/\bssh\s+\$Target\b/);
    expectNoMutatingCommands(content);
  });

  it("soak wrapper calls the live audit script with bounded samples", async () => {
    const content = await read("scripts/canary-soak-readonly.ps1");

    for (const expected of [
      "canary-live-audit-readonly.ps1",
      "Samples = 6",
      "IntervalSeconds = 300",
      "canary-soak-summary.md",
      "canary-soak-summary.json",
      "canary-soak-sample-table.md",
      "canary-soak-checklist.md",
      "restart_counts_stable",
      "send_timestamp_advanced",
      "recent_event_timestamp_advanced",
      "active_spool_stable_zero"
    ]) {
      expect(content).toContain(expected);
    }

    expectNoMutatingCommands(content);
  });

  it("report summarizer is evidence-only and local", async () => {
    const content = await read("scripts/canary-report-summarize-local.ps1");

    for (const expected of [
      "EvidenceRoot = \".smoke\"",
      "canary-operator-summary.md",
      "canary-operator-summary.json",
      "canary-live-audit",
      "canary-soak",
      "canary-service-harden-apply",
      "canary-baseline-audit",
      "canary-promote-plan",
      "live_ssh_used = $false",
      "production_mutation = $false"
    ]) {
      expect(content).toContain(expected);
    }

    expect(content).not.toMatch(/\bssh\s+\S+/i);
    expectNoMutatingCommands(content);
  });

  it("package scripts expose canary live audit commands", async () => {
    const packageJson = JSON.parse(await read("package.json"));

    expect(packageJson.scripts["canary:live-audit"]).toContain("canary-live-audit-readonly.ps1");
    expect(packageJson.scripts["canary:soak"]).toContain("canary-soak-readonly.ps1");
    expect(packageJson.scripts["canary:report-summary"]).toContain("canary-report-summarize-local.ps1");

    const packageScript = await read("scripts/package-agent-local.ps1");
    expect(packageScript).toContain('@{ Source = "docs"; Relative = "docs" }');
    expect(packageScript).toContain('@{ Source = "scripts"; Relative = "scripts" }');
  });

  it("gates include only the non-live report summarizer", async () => {
    const releaseGate = await read("scripts/release-gate-local.ps1");
    const canaryGate = await read("scripts/canary-baseline-gate-local.ps1");

    expect(releaseGate).toContain("canary-report-summarize-local.ps1");
    expect(canaryGate).toContain("canary-report-summarize-local.ps1");
    expect(releaseGate).not.toContain("canary-live-audit-readonly.ps1");
    expect(canaryGate).not.toContain("canary-live-audit-readonly.ps1");
    expect(releaseGate).not.toContain("canary-soak-readonly.ps1");
    expect(canaryGate).not.toContain("canary-soak-readonly.ps1");
    expectNoMutatingCommands(releaseGate);
    expectNoMutatingCommands(canaryGate);
  });
});

describe("canary live audit docs", () => {
  it("document read-only boundaries and retained canary policies", async () => {
    const docs = [
      await read("docs/ops/canary-live-audit-readonly.md"),
      await read("docs/ops/canary-soak-observation.md"),
      await read("docs/ops/canary-operator-reporting.md"),
      await read("docs/ops/canary-service-baseline-hardening.md"),
      await read("README.md"),
      await read("docs/OPERATIONS.md"),
      await read("docs/SECURITY.md")
    ].join("\n");

    for (const expected of [
      "read-only",
      "explicit operator authorization",
      "No raw logs",
      "No secret",
      "Archived spool",
      "stale prior HTTP error timestamp",
      "LAX Codex runtime",
      "Raw Hub public exposure",
      "not a production rename",
      "rollback planner"
    ]) {
      expect(docs).toContain(expected);
    }
  });

  it("avoid live mutation command examples in new docs", async () => {
    const files = [
      "docs/ops/canary-live-audit-readonly.md",
      "docs/ops/canary-soak-observation.md",
      "docs/ops/canary-operator-reporting.md"
    ];

    for (const file of files) {
      const content = await read(file);
      expect(content).not.toMatch(/TELEMETRY_NODE_SECRET\s*=/);
      expect(content).not.toMatch(/TELEMETRY_READ_TOKEN\s*=/);
      expect(content).not.toMatch(/Authorization:\s*\S+/);
      expect(content).not.toMatch(/Cookie:\s*\S+/i);
      expectNoMutatingCommands(content);
    }
  });
});
