import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { runAgentConfigDoctor } from "../src/deployment/configDoctor.js";
import { buildDeploymentPlan } from "../src/deployment/deployPlans.js";
import { findForbiddenTelemetryMarkers } from "../src/telemetry/forbiddenMarkers.js";

async function writeNodeConfig(value: unknown): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "jta-readiness-"));
  const file = path.join(dir, "node.json");
  await writeFile(file, JSON.stringify(value, null, 2));
  return file;
}

async function writeEnv(value: string): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "jta-readiness-env-"));
  const file = path.join(dir, "agent.local.env");
  await writeFile(file, value);
  return file;
}

describe("agent config doctor", () => {
  const secretEnvName = "TELEMETRY_NODE_" + "SECRET";

  it("passes a valid generic server example without printing forbidden markers", () => {
    const result = runAgentConfigDoctor({
      nodeConfigPath: "deploy/examples/general-linux-agent.node.json",
      mode: "Server",
      noNetwork: true,
      env: { TELEMETRY_OUTPUT_MODE: "file" }
    });

    expect(result.ok).toBe(true);
    expect(result.safe.secret_values_printed).toBe(false);
    expect(result.safe.auth_paths_printed).toBe(false);
    expect(findForbiddenTelemetryMarkers(result)).toEqual([]);
  });

  it("accepts a UTF-8 BOM on a protected node config", async () => {
    const nodeConfigPath = await writeNodeConfig({
      node_id: "fixture-workstation-node",
      hostname: "fixture-workstation",
      region: "local",
      role: "message-gateway",
      provider: "local",
      collectors: [{ name: "message-gateway-readiness", enabled: false }]
    });
    const raw = await readFile(nodeConfigPath, "utf8");
    await writeFile(nodeConfigPath, `\uFEFF${raw}`);

    const result = runAgentConfigDoctor({ nodeConfigPath, mode: "Server", noNetwork: true, env: { TELEMETRY_OUTPUT_MODE: "file" } });

    expect(result.checks.find((check) => check.name === "node_config_parse")).toMatchObject({ status: "pass" });
  });

  it("fails strict production checks when the upload secret is missing", async () => {
    const nodeConfigPath = await writeNodeConfig({
      node_id: "example-linux-01",
      hostname: "example-linux-01",
      region: "local",
      role: "general-linux-node",
      provider: "local",
      collectors: [{ name: "node-info", enabled: true }]
    });
    const envPath = await writeEnv([
      "TELEMETRY_OUTPUT_MODE=file,http",
      "TELEMETRY_HUB_URL=http://127.0.0.1:3000/v1/events",
      "STATE_PATH=.smoke/test/agent-state.json",
      "SPOOL_DIR=.smoke/test/spool",
      "TELEMETRY_LOG_DIR=.smoke/test/logs"
    ].join("\n"));

    const result = runAgentConfigDoctor({ nodeConfigPath, envPath, strictProduction: true, noNetwork: true, env: {} });

    expect(result.ok).toBe(false);
    expect(result.checks.find((check) => check.name === "node_secret")).toMatchObject({ status: "fail" });
    expect(findForbiddenTelemetryMarkers(result)).toEqual([]);
  });

  it("fails strict placeholder secrets without returning the secret value", async () => {
    const nodeConfigPath = await writeNodeConfig({
      node_id: "example-linux-01",
      hostname: "example-linux-01",
      region: "local",
      role: "general-linux-node",
      provider: "local",
      collectors: [{ name: "node-info", enabled: true }]
    });
    const envPath = await writeEnv([
      "TELEMETRY_OUTPUT_MODE=file,http",
      "TELEMETRY_HUB_URL=http://127.0.0.1:3000/v1/events",
      `${secretEnvName}=replace-with-real-secret`,
      "STATE_PATH=.smoke/test/agent-state.json",
      "SPOOL_DIR=.smoke/test/spool",
      "TELEMETRY_LOG_DIR=.smoke/test/logs"
    ].join("\n"));

    const result = runAgentConfigDoctor({ nodeConfigPath, envPath, strictProduction: true, noNetwork: true, env: {} });

    expect(result.ok).toBe(false);
    expect(result.checks.find((check) => check.name === "node_secret_quality")).toMatchObject({
      status: "fail",
      details: { secret_present: true, placeholder_detected: true }
    });
    expect(JSON.stringify(result)).not.toContain("replace-with-real-secret");
  });

  it("fails unknown and arbitrary shell command collectors", async () => {
    const unknownPath = await writeNodeConfig({
      node_id: "bad",
      hostname: "bad",
      region: "local",
      role: "test",
      provider: "local",
      collectors: [{ name: "unknown-collector", enabled: true }]
    });
    const shellPath = await writeNodeConfig({
      node_id: "bad",
      hostname: "bad",
      region: "local",
      role: "test",
      provider: "local",
      collectors: [{ name: "shell-command", enabled: true, command: "whoami" }]
    });

    expect(runAgentConfigDoctor({ nodeConfigPath: unknownPath, mode: "Server", env: {} }).ok).toBe(false);
    const shellResult = runAgentConfigDoctor({ nodeConfigPath: shellPath, mode: "Server", env: {} });
    expect(shellResult.ok).toBe(false);
    expect(shellResult.checks.find((check) => check.name === "arbitrary_shell_collector")).toMatchObject({ status: "fail" });
  });
});

describe("deployment dry-run plans", () => {
  it("renders install, upgrade, and uninstall plans without forbidden markers or mutation", () => {
    for (const action of ["install", "upgrade", "uninstall"] as const) {
      const plan = buildDeploymentPlan({
        action,
        nodeConfigPath: "deploy/examples/general-linux-agent.node.json",
        envExamplePath: "deploy/examples/general-linux-daemon.env.example"
      });

      expect(plan.dry_run_only).toBe(true);
      expect(plan.production_mutation).toBe(false);
      expect(plan.safe.secret_values_rendered).toBe(false);
      expect(plan.safe.mutating_commands_executed).toBe(false);
      expect(findForbiddenTelemetryMarkers(plan)).toEqual([]);
    }
  });
});

describe("deployment readiness scripts and examples", () => {
  it("dry-run wrappers do not invoke remote or production-mutating commands", async () => {
    const files = [
      "scripts/install-agent-dry-run.ps1",
      "scripts/upgrade-agent-dry-run.ps1",
      "scripts/uninstall-agent-dry-run.ps1"
    ];
    for (const file of files) {
      const content = await readFile(file, "utf8");
      expect(content).not.toMatch(/\bssh\b|\bscp\b|\brsync\b|Invoke-Command/i);
      expect(content).not.toMatch(/systemctl\s+(start|stop|restart|enable|disable)/i);
      expect(content).not.toMatch(/docker\s+compose\s+(up|down|restart)/i);
    }
  });

  it("release gate includes the required local checks", async () => {
    const content = await readFile("scripts/release-gate-local.ps1", "utf8");
    for (const expected of [
      "npm run typecheck",
      "npm test",
      "npm run build",
      "docker compose config",
      "scan-secrets-light",
      "git diff --check",
      "validate-local.ps1",
      "agent-once Fixture FileOnly",
      "agent-once LocalWindows FileOnly",
      "smoke-server-agent.ps1",
      "smoke-server-daemon.ps1",
      "smoke-local-hub-agent-e2e Once",
      "smoke-local-hub-agent-e2e Daemon",
      "doctor-agent-config",
      "package-agent-local.ps1",
      "install-agent-dry-run.ps1",
      "upgrade-agent-dry-run.ps1",
      "uninstall-agent-dry-run.ps1"
    ]) {
      expect(content).toContain(expected);
    }
  });

  it("package script excludes forbidden files from artifacts", async () => {
    const content = await readFile("scripts/package-agent-local.ps1", "utf8");
    for (const expected of [".env", ".env.*", "auth.json", "node_modules", ".smoke", "state", "logs", "raw.local-only"]) {
      expect(content).toContain(expected);
    }
    expect(content).toContain("forbidden_marker_scan");
  });

  it("deployment examples contain no real secrets or token-bearing URLs", async () => {
    const files = [
      "deploy/examples/agent-deployment-manifest.example.json",
      "deploy/examples/general-linux-install-plan.example.json",
      "deploy/examples/general-linux-upgrade-plan.example.json",
      "deploy/examples/general-linux-uninstall-plan.example.json"
    ];
    for (const file of files) {
      const content = await readFile(file, "utf8");
      expect(content).not.toMatch(/TELEMETRY_NODE_SECRET\s*=/);
      expect(content).not.toMatch(/access_token|refresh_token|Authorization:|Cookie:|Set-Cookie:/i);
      expect(content).not.toMatch(/https?:\/\/[^/\s]+:[^@\s]+@/);
      expect(findForbiddenTelemetryMarkers(JSON.parse(content))).toEqual([]);
    }
  });
});
