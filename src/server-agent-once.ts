import { pathToFileURL } from "node:url";
import { runServerOnce, type ServerOnceOutput, type ServerOnceResult } from "./serverOnce.js";
import { sanitizeErrorForTelemetry } from "./telemetry/sanitize.js";

function readFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

function output(value: string | undefined): ServerOnceOutput {
  if (value === undefined || value === "FileOnly" || value.toLowerCase() === "fileonly") return "FileOnly";
  if (value === "Push" || value.toLowerCase() === "push") return "Push";
  throw new Error(`Invalid output: ${value}`);
}

export function parseServerOnceArgs(env: NodeJS.ProcessEnv = process.env, args = process.argv.slice(2)) {
  return {
    configPath: readFlag(args, "--config") ?? env.TELEMETRY_NODE_CONFIG_PATH ?? "deploy/examples/general-linux-agent.node.json",
    output: output(readFlag(args, "--output")),
    outFile: readFlag(args, "--out-file") ?? env.TELEMETRY_BATCH_OUTPUT_FILE ?? ".smoke/server.batch.safe.json",
    hubUrl: readFlag(args, "--hub-url") ?? env.TELEMETRY_HUB_URL,
    writeSecret: readFlag(args, "--write-secret") ?? env.TELEMETRY_NODE_SECRET,
    keyId: readFlag(args, "--key-id") ?? env.TELEMETRY_NODE_KEY_ID
  };
}

async function main(): Promise<void> {
  printResult(await runServerOnce(parseServerOnceArgs()));
}

function printResult(result: ServerOnceResult): void {
  console.log(`node_id=${result.node_id}`);
  console.log(`events_count=${result.events_count}`);
  console.log(`event_types=${result.event_types.join(",")}`);
  console.log(`output_file=${result.output_file}`);
  console.log(`forbidden_markers_found=${result.forbidden_markers_found}`);
  console.log(`upload=${result.upload}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    const safe = sanitizeErrorForTelemetry(error, "server_once_error");
    console.error(`error=${safe.message}`);
    process.exitCode = 1;
  });
}
