import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

async function read(path: string): Promise<string> {
  return readFile(path, "utf8");
}

function expectNoLiveInvocation(content: string): void {
  expect(content).not.toMatch(/(^|\n)\s*(&\s*)?ssh\s+[-\w]/i);
  expect(content).not.toMatch(/\bscp\s+\S+|\brsync\s+\S+|Invoke-Command/i);
  expect(content).not.toMatch(/(^|\n)\s*systemctl\s+(start|stop|restart|enable|disable)\b/i);
  expect(content).not.toMatch(/(^|\n)\s*docker\s+(stop|start|restart|rm)\b/i);
  expect(content).not.toMatch(/(^|\n)\s*docker\s+compose\s+(up|down|restart)\b/i);
}

describe("canary service hardening scripts", () => {
  it("service baseline planner is plan-only and covers retained canary operations", async () => {
    const content = await read("scripts/canary-service-baseline-plan-local.ps1");

    for (const expected of [
      "ObserveOnly",
      "StabilizeCanary",
      "RollbackReady",
      "service-baseline-plan.md",
      "service-baseline-plan.json",
      "operation-checklist.md",
      "rollback-checklist.md",
      "plan_only = $true",
      "commands_executed = $false",
      "current_restart_policy_concern",
      "archived_spool",
      "lax_codex_runtime",
      "raw_hub_public_exposure"
    ]) {
      expect(content).toContain(expected);
    }

    expectNoLiveInvocation(content);
  });

  it("agent supervision planner compares all expected options without live mutation", async () => {
    const content = await read("scripts/canary-agent-supervision-plan-local.ps1");

    for (const expected of [
      "Keep current container-only canary",
      "Docker restart policy for canary container",
      "Systemd wrapper managing canary container",
      "Compose-managed canary stack",
      "agent-supervision-options.md",
      "agent-supervision-options.json",
      "recommended-supervision-path.md",
      "recommended-supervision-path.json",
      "Do not change the live canary",
      "current_restart_policy_concern",
      "production_mutation = $false"
    ]) {
      expect(content).toContain(expected);
    }

    expectNoLiveInvocation(content);
  });

  it("live audit contract defines allowed read-only checks and forbidden mutations", async () => {
    const content = await read("scripts/canary-live-audit-contract-local.ps1");

    for (const expected of [
      "canary-live-audit-contract.md",
      "canary-live-audit-contract.json",
      "contract_only",
      "allowed_read_only_commands",
      "forbidden_mutating_commands",
      "systemctl is-active",
      "docker ps with safe format fields",
      "systemctl start",
      "docker stop",
      "docker compose up",
      "spool flush",
      "required_redactions",
      "raw logs",
      "marker_scan"
    ]) {
      expect(content).toContain(expected);
    }

    expectNoLiveInvocation(content);
  });

  it("release and canary gates reference new planning scripts safely", async () => {
    const releaseGate = await read("scripts/release-gate-local.ps1");
    const canaryGate = await read("scripts/canary-baseline-gate-local.ps1");

    for (const expected of [
      "canary-service-baseline-plan-local.ps1",
      "canary-agent-supervision-plan-local.ps1",
      "canary-live-audit-contract-local.ps1"
    ]) {
      expect(releaseGate).toContain(expected);
      expect(canaryGate).toContain(expected);
    }

    expect(releaseGate).toContain("local_canary_evidence_missing");
    expect(canaryGate).toContain("canary-baseline-audit.ps1");
    expectNoLiveInvocation(releaseGate);
    expectNoLiveInvocation(canaryGate);
  });

  it("package and npm scripts include canary hardening tools", async () => {
    const packageJson = JSON.parse(await read("package.json"));
    expect(packageJson.scripts["canary:audit"]).toContain("canary-baseline-audit.ps1");
    expect(packageJson.scripts["canary:baseline-gate"]).toContain("canary-baseline-gate-local.ps1");
    expect(packageJson.scripts["canary:service-plan"]).toContain("canary-service-baseline-plan-local.ps1");
    expect(packageJson.scripts["canary:supervision-plan"]).toContain("canary-agent-supervision-plan-local.ps1");
    expect(packageJson.scripts["canary:live-audit-contract"]).toContain("canary-live-audit-contract-local.ps1");
    expect(packageJson.scripts["canary:rollback-plan"]).toContain("canary-rollback-plan-local.ps1");

    const packageScript = await read("scripts/package-agent-local.ps1");
    expect(packageScript).toContain('@{ Source = "docs"; Relative = "docs" }');
    expect(packageScript).toContain('@{ Source = "scripts"; Relative = "scripts" }');
  });
});

describe("canary service hardening docs", () => {
  it("document boundaries and operational policies", async () => {
    const docs = [
      await read("docs/ops/canary-service-baseline-hardening.md"),
      await read("docs/ops/canary-agent-supervision-options.md"),
      await read("docs/ops/canary-live-audit-contract.md"),
      await read("docs/ops/canary-stabilization-to-production-boundary.md"),
      await read("README.md"),
      await read("docs/OPERATIONS.md"),
      await read("docs/SECURITY.md")
    ].join("\n");

    for (const expected of [
      "not authorize production rename",
      "Do not rename canary services",
      "restart policy is currently reported as `no`",
      "Do not change the live canary now",
      "Reverse tunnel",
      "Do not flush archived spool automatically",
      "stale prior HTTP error timestamp",
      "Do not expose raw Hub publicly",
      "Do not modify existing LAX Codex runtime",
      "dashboard, mobile, watch, notify",
      "explicit authorization"
    ]) {
      expect(docs).toContain(expected);
    }
  });

  it("avoid real secret assignments and live mutation command examples in docs", async () => {
    const files = [
      "docs/ops/canary-service-baseline-hardening.md",
      "docs/ops/canary-agent-supervision-options.md",
      "docs/ops/canary-live-audit-contract.md",
      "docs/ops/canary-stabilization-to-production-boundary.md"
    ];

    for (const file of files) {
      const content = await read(file);
      expect(content).not.toMatch(/TELEMETRY_NODE_SECRET\s*=/);
      expect(content).not.toMatch(/TELEMETRY_READ_TOKEN\s*=/);
      expect(content).not.toMatch(/Authorization:\s*\S+/);
      expect(content).not.toMatch(/Cookie:\s*\S+/i);
      expect(content).not.toMatch(/(^|\n)\s*systemctl\s+(start|stop|restart|enable|disable)\b/i);
      expect(content).not.toMatch(/(^|\n)\s*docker\s+(stop|start|restart|rm)\b/i);
      expect(content).not.toMatch(/(^|\n)\s*docker\s+compose\s+(up|down|restart)\b/i);
      expect(content).not.toMatch(/\b(scp|rsync)\s+\S+/i);
    }
  });
});
