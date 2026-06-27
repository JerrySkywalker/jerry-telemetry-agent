import { pathToFileURL } from "node:url";
import { runAgentConfigDoctor, type AgentDoctorMode } from "./deployment/configDoctor.js";

function readFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

function hasFlag(args: string[], name: string): boolean {
  return args.includes(name);
}

function mode(value: string | undefined): AgentDoctorMode {
  if (value === undefined || value === "Server" || value === "Local" || value === "LaxCodex") return value ?? "Server";
  throw new Error(`Invalid doctor mode: ${value}`);
}

export function parseDoctorCliArgs(args = process.argv.slice(2)) {
  return {
    envPath: readFlag(args, "--env-path"),
    nodeConfigPath: readFlag(args, "--node-config-path"),
    strictProduction: hasFlag(args, "--strict-production"),
    noNetwork: hasFlag(args, "--no-network"),
    mode: mode(readFlag(args, "--mode"))
  };
}

async function main(): Promise<void> {
  const result = runAgentConfigDoctor(parseDoctorCliArgs());
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.ok) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`error=${(error as Error).message.replace(/auth\.json/gi, "auth_file")}`);
    process.exitCode = 1;
  });
}
