import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { buildDeploymentPlan, type DeploymentPlanAction } from "./deployment/deployPlans.js";

function readFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

function action(value: string | undefined): DeploymentPlanAction {
  if (value === "install" || value === "upgrade" || value === "uninstall") return value;
  throw new Error(`Invalid deployment plan action: ${value ?? ""}`);
}

export function parseDeploymentPlanCliArgs(args = process.argv.slice(2)) {
  return {
    action: action(readFlag(args, "--action")),
    nodeConfigPath: readFlag(args, "--node-config-path") ?? "deploy/examples/general-linux-agent.node.json",
    envExamplePath: readFlag(args, "--env-example-path"),
    installRoot: readFlag(args, "--install-root"),
    stateDir: readFlag(args, "--state-dir"),
    logDir: readFlag(args, "--log-dir"),
    user: readFlag(args, "--user"),
    outputDir: readFlag(args, "--output-dir") ?? ".smoke/deploy-plan"
  };
}

async function main(): Promise<void> {
  const options = parseDeploymentPlanCliArgs();
  const plan = buildDeploymentPlan(options);
  const outputDir = path.resolve(options.outputDir);
  await mkdir(outputDir, { recursive: true });
  const planFile = path.join(outputDir, `${plan.action}-plan.json`);
  const commandFile = path.join(outputDir, `${plan.action}-commands.txt`);
  const checklistFile = path.join(outputDir, `${plan.action}-safety-checklist.txt`);
  await writeFile(planFile, `${JSON.stringify(plan, null, 2)}\n`, { mode: 0o600 });
  await writeFile(commandFile, `${plan.command_plan.join("\n")}\n`, { mode: 0o600 });
  await writeFile(checklistFile, `${plan.safety_checklist.join("\n")}\n`, { mode: 0o600 });
  process.stdout.write(`${JSON.stringify({
    action: plan.action,
    dry_run_only: plan.dry_run_only,
    production_mutation: plan.production_mutation,
    plan_file: planFile,
    command_plan_file: commandFile,
    safety_checklist_file: checklistFile,
    forbidden_markers_found: plan.safe.forbidden_markers_found.length > 0
  }, null, 2)}\n`);
  if (plan.safe.forbidden_markers_found.length > 0) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`error=${(error as Error).message}`);
    process.exitCode = 1;
  });
}
