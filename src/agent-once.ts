import { pathToFileURL } from "node:url";
import { runAgentOnce, type AgentOnceOptions, type AgentOnceOutput } from "./localOnce.js";
import type { LocalCollectionMode } from "./collectors/local.js";
import { sanitizeErrorForTelemetry } from "./telemetry/sanitize.js";

function readFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

function hasFlag(args: string[], name: string): boolean {
  return args.includes(name);
}

function mode(value: string | undefined): LocalCollectionMode {
  if (value === undefined || value === "Fixture" || value.toLowerCase() === "fixture") return "Fixture";
  if (value === "LocalWindows" || value.toLowerCase() === "localwindows") return "LocalWindows";
  throw new Error(`Invalid mode: ${value}`);
}

function output(value: string | undefined): AgentOnceOutput {
  if (value === undefined || value === "FileOnly" || value.toLowerCase() === "fileonly") return "FileOnly";
  if (value === "Push" || value.toLowerCase() === "push") return "Push";
  throw new Error(`Invalid output: ${value}`);
}

export function parseAgentOnceOptions(env: NodeJS.ProcessEnv = process.env, args = process.argv.slice(2)): AgentOnceOptions {
  const nodeId = readFlag(args, "--node-id") ?? env.TELEMETRY_NODE_ID ?? "local-win-dev-01";
  return {
    mode: mode(readFlag(args, "--mode")),
    output: output(readFlag(args, "--output")),
    nodeId,
    hostname: readFlag(args, "--hostname") ?? env.TELEMETRY_HOSTNAME ?? nodeId,
    region: readFlag(args, "--region") ?? env.TELEMETRY_REGION ?? "local",
    role: readFlag(args, "--role") ?? env.TELEMETRY_NODE_ROLE ?? "dev-node",
    provider: readFlag(args, "--provider") ?? env.TELEMETRY_PROVIDER ?? "local",
    hubUrl: readFlag(args, "--hub-url") ?? env.TELEMETRY_HUB_URL,
    writeSecret: readFlag(args, "--write-secret") ?? env.TELEMETRY_NODE_SECRET,
    readToken: readFlag(args, "--read-token") ?? env.TELEMETRY_READ_TOKEN,
    outFile: readFlag(args, "--out-file") ?? env.TELEMETRY_BATCH_OUTPUT_FILE ?? ".smoke/telemetry-batch.safe.json",
    skipReadback: hasFlag(args, "--skip-readback"),
    keyId: readFlag(args, "--key-id") ?? env.TELEMETRY_NODE_KEY_ID,
    customJsonFile: readFlag(args, "--custom-json-file") ?? env.TELEMETRY_CUSTOM_JSON_PATH,
    serviceHealthFile: readFlag(args, "--service-health-file") ?? env.TELEMETRY_SERVICE_HEALTH_PATH
  };
}

async function main(): Promise<void> {
  const result = await runAgentOnce(parseAgentOnceOptions());
  printResult(result);
}

function printResult(result: Awaited<ReturnType<typeof runAgentOnce>>): void {
  console.log(`node_id=${result.node_id}`);
  console.log(`events_count=${result.events_count}`);
  console.log(`event_types=${result.event_types.join(",")}`);
  console.log(`output_file=${result.output_file}`);
  console.log(`forbidden_markers_found=${result.forbidden_markers_found}`);
  console.log(`upload=${result.upload}`);
  console.log(`readback=${result.readback}`);
  if (result.readback_node_seen !== undefined) {
    console.log(`readback_node_seen=${result.readback_node_seen}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    const safe = sanitizeErrorForTelemetry(error, "agent_once_error");
    console.error(`error=${safe.message}`);
    process.exitCode = 1;
  });
}
