import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

async function read(path: string): Promise<string> {
  return readFile(path, "utf8");
}

describe("canary baseline tooling", () => {
  it("canary audit script runs from local evidence and refuses live mode by default", async () => {
    const content = await read("scripts/canary-baseline-audit.ps1");

    for (const expected of [
      "canary-stabilize-*",
      "http-canary-observe-03-*",
      "canary-promote-plan-*",
      "canary-baseline-audit-summary.md",
      "canary-baseline-audit-summary.json",
      "canary-baseline-checklist.md",
      "Live canary audit mode is refused by default",
      "live_ssh_used=false",
      "production_mutation=false",
      "Archived HTTP spool retention"
    ]) {
      expect(content).toContain(expected);
    }

    expect(content).not.toMatch(/(^|\n)\s*(&\s*)?ssh\b/i);
    expect(content).not.toMatch(/\bscp\s+\S+|\brsync\s+\S+|Invoke-Command/i);
    expect(content).not.toMatch(/systemctl\s+(start|stop|restart|enable|disable)/i);
    expect(content).not.toMatch(/docker\s+(stop|start|restart|rm)\b/i);
  });

  it("canary baseline gate composes required local checks without SSH", async () => {
    const content = await read("scripts/canary-baseline-gate-local.ps1");

    for (const expected of [
      "npm run typecheck",
      "npm test",
      "npm run build",
      "docker compose config",
      "scan-secrets-light",
      "git diff --check",
      "validate-local.ps1",
      "release-gate-local.ps1",
      "canary-baseline-audit.ps1",
      "stack-release-candidate-local.ps1",
      "sibling_hub_repo_missing",
      "production_mutation=false",
      "live_ssh_used=false"
    ]) {
      expect(content).toContain(expected);
    }

    expect(content).not.toMatch(/(^|\n)\s*(&\s*)?ssh\b/i);
    expect(content).not.toMatch(/\bscp\s+\S+|\brsync\s+\S+|Invoke-Command/i);
  });

  it("rollback planner is plan-only and does not execute mutating commands", async () => {
    const content = await read("scripts/canary-rollback-plan-local.ps1");

    for (const expected of [
      "StopHttpCanary",
      "FileOnlyRollback",
      "FullCanaryStop",
      "plan_only = $true",
      "commands_executed = $false",
      "preserve_spool",
      "flushes_archived_spool = $false",
      "touches_lax_codex_runtime = $false",
      "rollback-plan.md",
      "rollback-plan.json",
      "rollback-checklist.md"
    ]) {
      expect(content).toContain(expected);
    }

    expect(content).not.toMatch(/(^|\n)\s*(&\s*)?ssh\b/i);
    expect(content).not.toMatch(/\bscp\s+\S+|\brsync\s+\S+|Invoke-Command/i);
    expect(content).not.toMatch(/systemctl\s+(start|stop|restart|enable|disable)/i);
    expect(content).not.toMatch(/docker\s+(stop|start|restart|rm)\b/i);
    expect(content).not.toMatch(/docker\s+compose\s+(up|down|restart)/i);
  });

  it("release gate integrates the canary audit only when local evidence exists", async () => {
    const content = await read("scripts/release-gate-local.ps1");

    expect(content).toContain("canary-baseline-audit.ps1 evidence");
    expect(content).toContain("canary-stabilize-*");
    expect(content).toContain("http-canary-observe-03-*");
    expect(content).toContain("canary-promote-plan-*");
    expect(content).toContain("local_canary_evidence_missing");
  });

  it("package script already includes the new docs and scripts through top-level packaging", async () => {
    const packageScript = await read("scripts/package-agent-local.ps1");
    expect(packageScript).toContain('@{ Source = "docs"; Relative = "docs" }');
    expect(packageScript).toContain('@{ Source = "scripts"; Relative = "scripts" }');

    for (const file of [
      "scripts/canary-baseline-audit.ps1",
      "scripts/canary-baseline-gate-local.ps1",
      "scripts/canary-rollback-plan-local.ps1",
      "docs/ops/canary-baseline-runbook.md",
      "docs/ops/canary-baseline-audit.md",
      "docs/ops/canary-rollback.md",
      "docs/ops/canary-promotion-policy.md"
    ]) {
      await expect(read(file)).resolves.toEqual(expect.any(String));
    }
  });
});

describe("canary baseline docs", () => {
  it("document the non-deployment boundary and retained canary policies", async () => {
    const docs = [
      await read("docs/ops/canary-baseline-runbook.md"),
      await read("docs/ops/canary-baseline-audit.md"),
      await read("docs/ops/canary-rollback.md"),
      await read("docs/ops/canary-promotion-policy.md")
    ].join("\n");

    for (const expected of [
      "does not promote the canary to production",
      "Do not touch the existing LAX Codex runtime",
      "Do not expose raw Hub publicly",
      "Do not flush archived spool automatically",
      "Do not restore archived spool automatically",
      "Do not delete archived spool",
      "stale prior HTTP error timestamp",
      "Live mode is intentionally refused",
      "Human approval remains required"
    ]) {
      expect(docs).toContain(expected);
    }
  });

  it("avoid live mutation command examples and real secret assignments", async () => {
    const files = [
      "docs/ops/canary-baseline-runbook.md",
      "docs/ops/canary-baseline-audit.md",
      "docs/ops/canary-rollback.md",
      "docs/ops/canary-promotion-policy.md"
    ];

    for (const file of files) {
      const content = await read(file);
      expect(content).not.toMatch(/TELEMETRY_NODE_SECRET\s*=/);
      expect(content).not.toMatch(/TELEMETRY_READ_TOKEN\s*=/);
      expect(content).not.toMatch(/Authorization:\s*\S+/i);
      expect(content).not.toMatch(/Cookie:\s*\S+/i);
      expect(content).not.toMatch(/\bsystemctl\s+(start|stop|restart|enable|disable)\b/i);
      expect(content).not.toMatch(/\bdocker\s+(stop|start|restart|rm)\b/i);
      expect(content).not.toMatch(/\bdocker\s+compose\s+(up|down|restart)\b/i);
      expect(content).not.toMatch(/\b(scp|rsync)\s+\S+/i);
    }
  });
});
