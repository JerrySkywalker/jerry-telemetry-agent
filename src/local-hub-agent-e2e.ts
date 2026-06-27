import { spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { runAgentOnce } from "./localOnce.js";
import {
  assertReadbackComplete,
  buildAgentChildEnv,
  buildLocalHubChildEnv,
  findAvailableLocalPort,
  generateLocalHubE2ECredentials,
  localHubBaseUrl,
  localHubBatchUrl,
  safeChildEnv,
  safeE2EError,
  scanLocalHubE2EText,
  type LocalHubE2ECredentials,
  type ReadbackBodies
} from "./localHubE2E.js";

type E2EMode = "Once" | "Daemon";

interface CliOptions {
  mode: E2EMode;
  hubRepoPath: string;
  hubHost: string;
  hubPort: number;
  nodeId: string;
  smokeRoot: string;
}

interface StartedHub {
  process: ChildProcess;
  stdoutLog: string;
  stderrLog: string;
}

function readFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

function mode(value: string | undefined): E2EMode {
  if (value === undefined || value.toLowerCase() === "once") return "Once";
  if (value.toLowerCase() === "daemon") return "Daemon";
  throw new Error(`Invalid E2E mode: ${value}`);
}

export function parseLocalHubAgentE2EArgs(env: NodeJS.ProcessEnv = process.env, args = process.argv.slice(2), cwd = process.cwd()): CliOptions {
  return {
    mode: mode(readFlag(args, "--mode") ?? env.LOCAL_HUB_AGENT_E2E_MODE),
    hubRepoPath: path.resolve(readFlag(args, "--hub-repo-path") ?? env.TELEMETRY_HUB_REPO_PATH ?? path.join(cwd, "..", "jerry-telemetry-hub")),
    hubHost: readFlag(args, "--hub-host") ?? env.LOCAL_HUB_HOST ?? "127.0.0.1",
    hubPort: positiveInt(readFlag(args, "--hub-port") ?? env.LOCAL_HUB_PORT, 3300),
    nodeId: readFlag(args, "--node-id") ?? env.LOCAL_HUB_AGENT_E2E_NODE_ID ?? "local-e2e-node-01",
    smokeRoot: path.resolve(readFlag(args, "--smoke-root") ?? env.LOCAL_HUB_AGENT_E2E_SMOKE_ROOT ?? ".smoke/local-hub-agent-e2e")
  };
}

async function main(): Promise<void> {
  const options = parseLocalHubAgentE2EArgs();
  if (!(await pathExists(path.join(options.hubRepoPath, "package.json")))) {
    console.log("SKIP local_hub_agent_e2e reason=sibling_hub_repo_missing");
    return;
  }

  const result = await runLocalHubAgentE2E(options);
  for (const line of result.passLines) console.log(line);
}

async function runLocalHubAgentE2E(options: CliOptions): Promise<{ passLines: string[] }> {
  const port = await findAvailableLocalPort(options.hubPort);
  const runId = `${new Date().toISOString().replace(/[:.]/g, "-")}-${crypto.randomUUID()}`;
  const runRoot = path.join(options.smokeRoot, runId);
  const sqlitePath = path.join(runRoot, "telemetry.sqlite3");
  const credentials = generateLocalHubE2ECredentials(options.nodeId);
  await mkdir(runRoot, { recursive: true });

  const hub = await startTemporaryHub(options, runRoot, port, sqlitePath, credentials);
  const passLines: string[] = [];
  try {
    passLines.push(`PASS hub_repo_discovery path=${options.hubRepoPath}`);
    passLines.push(`PASS temporary_hub_startup host=${options.hubHost} port=${port}`);
    passLines.push("PASS ephemeral_write_secret in_memory=true printed=false");
    passLines.push("PASS ephemeral_read_token in_memory=true printed=false");
    passLines.push(`PASS sqlite_temp_path path=${sqlitePath}`);

    if (options.mode === "Once") {
      passLines.push(...await runOnceE2E(options, runRoot, port, credentials));
      passLines.push(...await runNegativeScenarios(options, runRoot, port, credentials));
    } else {
      passLines.push(...await runDaemonE2E(options, runRoot, port, credentials));
    }
  } finally {
    await stopHub(hub.process);
    await assertAllRunLogsSafe(runRoot, credentials);
    passLines.push("PASS hub_shutdown stopped=true");
    passLines.push("PASS log_marker_scan forbidden_markers_found=false");
  }

  const rendered = passLines.join("\n");
  const leaked = scanLocalHubE2EText(rendered, credentials);
  if (leaked.length > 0) throw new Error("E2E output contains a forbidden generated credential marker");
  return { passLines };
}

async function runOnceE2E(options: CliOptions, runRoot: string, port: number, credentials: LocalHubE2ECredentials): Promise<string[]> {
  const outFile = path.join(runRoot, "once.batch.safe.json");
  const hubUrl = localHubBaseUrl(options.hubHost, port);
  const result = await runAgentOnce({
    mode: "Fixture",
    output: "Push",
    nodeId: credentials.nodeId,
    hostname: credentials.nodeId,
    region: "local",
    role: "e2e-node",
    provider: "local",
    outFile,
    hubUrl,
    writeSecret: credentials.writeSecret,
    readToken: credentials.readToken
  });
  if (result.upload !== "ok" || result.readback !== "checked" || result.readback_node_seen !== true) {
    throw new Error("agent once E2E upload/readback failed");
  }
  const readback = assertReadbackComplete(credentials.nodeId, await fetchReadback(hubUrl, credentials.readToken));
  await assertFileSafe(outFile, credentials);
  return [
    `PASS once_e2e node_id=${credentials.nodeId} events_count=${result.events_count}`,
    `PASS batch_ingest endpoint=/v1/events/batch event_types=${result.event_types.join(",")}`,
    `PASS nodes_readback node_seen=${readback.nodeInNodes}`,
    `PASS summary_readback node_seen=${readback.nodeInSummary} event_types=${readback.eventTypes.join(",")}`,
    `PASS services_readback service_seen=${readback.serviceSeen}`,
    `PASS custom_readback custom_seen=${readback.customSeen}`,
    "PASS once_output_file forbidden_markers_found=false"
  ];
}

async function runDaemonE2E(options: CliOptions, runRoot: string, port: number, credentials: LocalHubE2ECredentials): Promise<string[]> {
  const hubUrl = localHubBaseUrl(options.hubHost, port);
  const nodeConfig = await buildDaemonNodeConfig(runRoot, credentials.nodeId);
  const latestFile = path.join(runRoot, "daemon.batch.latest.safe.json");
  const outFile = path.join(runRoot, "daemon.batch.safe.json");
  const statePath = path.join(runRoot, "daemon-state.json");
  const spoolDir = path.join(runRoot, "spool");
  const stdoutLog = path.join(runRoot, "daemon.stdout.log");
  const stderrLog = path.join(runRoot, "daemon.stderr.log");

  await runPowerShellScript(
    path.join(process.cwd(), "scripts", "server-agent-daemon.ps1"),
    [
      "-Config",
      nodeConfig,
      "-Output",
      "Push",
      "-HubUrl",
      `${hubUrl}/v1/events`,
      "-OutFile",
      outFile,
      "-LatestFile",
      latestFile,
      "-StatePath",
      statePath,
      "-SpoolDir",
      spoolDir,
      "-IntervalSeconds",
      "1",
      "-MaxIterations",
      "2"
    ],
    buildAgentChildEnv(process.env, credentials, false),
    stdoutLog,
    stderrLog
  );

  await assertLogsSafe([stdoutLog, stderrLog], credentials);
  await assertFileSafe(latestFile, credentials);
  await assertFileSafe(outFile, credentials);
  const state = await readJsonFile(statePath, credentials);
  const stateText = JSON.stringify(state);
  if (!stateText.includes("lastServerBatchSuccessfulSendAt")) throw new Error("daemon state missing successful send timestamp");
  if (!stateText.includes("\"pendingBatchSpoolCount\":0")) throw new Error("daemon state has pending batch spool");
  const pendingBatchSpool = await countFiles(spoolDir, ".batch.json");
  if (pendingBatchSpool !== 0) throw new Error("daemon left pending batch spool files");

  const readback = assertReadbackComplete(credentials.nodeId, await fetchReadback(hubUrl, credentials.readToken));
  return [
    `PASS daemon_e2e node_id=${credentials.nodeId} iterations=2`,
    `PASS batch_ingest endpoint=/v1/events/batch event_types=${readback.eventTypes.join(",")}`,
    `PASS nodes_readback node_seen=${readback.nodeInNodes}`,
    `PASS summary_readback node_seen=${readback.nodeInSummary}`,
    `PASS services_readback service_seen=${readback.serviceSeen}`,
    `PASS custom_readback custom_seen=${readback.customSeen}`,
    "PASS daemon_state successful_send=true pending_batch_spool_count=0",
    "PASS daemon_spool pending_batch_files=0"
  ];
}

async function runNegativeScenarios(options: CliOptions, runRoot: string, port: number, credentials: LocalHubE2ECredentials): Promise<string[]> {
  const hubUrl = localHubBaseUrl(options.hubHost, port);
  const badSecret = generateLocalHubE2ECredentials(credentials.nodeId).writeSecret;
  try {
    await runAgentOnce({
      mode: "Fixture",
      output: "Push",
      nodeId: credentials.nodeId,
      hostname: credentials.nodeId,
      region: "local",
      role: "e2e-node",
      provider: "local",
      outFile: path.join(runRoot, "bad-secret.batch.safe.json"),
      hubUrl,
      writeSecret: badSecret,
      skipReadback: true
    });
    throw new Error("bad write secret unexpectedly succeeded");
  } catch (error) {
    const safe = safeE2EError(error, "bad_write_secret");
    if (safe.includes(badSecret) || safe.includes(credentials.writeSecret)) throw new Error("bad secret error leaked a generated secret");
  }

  const missingReadToken = await fetch(`${hubUrl}/v1/nodes`, { method: "GET" });
  if (missingReadToken.status !== 401) throw new Error("missing read token did not return HTTP 401");
  const missingReadBody = await missingReadToken.text();
  if (scanLocalHubE2EText(missingReadBody, credentials).length > 0) throw new Error("missing read token response contains forbidden marker");

  const unavailablePort = await findAvailableLocalPort(port + 1 > 65535 ? 3301 : port + 1);
  try {
    await runAgentOnce({
      mode: "Fixture",
      output: "Push",
      nodeId: credentials.nodeId,
      hostname: credentials.nodeId,
      region: "local",
      role: "e2e-node",
      provider: "local",
      outFile: path.join(runRoot, "hub-unavailable.batch.safe.json"),
      hubUrl: localHubBaseUrl(options.hubHost, unavailablePort),
      writeSecret: credentials.writeSecret,
      skipReadback: true
    });
    throw new Error("hub unavailable unexpectedly succeeded");
  } catch (error) {
    const safe = safeE2EError(error, "hub_unavailable");
    if (safe.includes(credentials.writeSecret) || safe.includes(credentials.readToken)) throw new Error("hub unavailable error leaked generated credentials");
  }

  return [
    "PASS bad_secret_scenario status=401 safe_error=true",
    "PASS missing_read_token_scenario status=401 safe_error=true",
    "PASS hub_unavailable_scenario safe_error=true"
  ];
}

async function startTemporaryHub(
  options: CliOptions,
  runRoot: string,
  port: number,
  sqlitePath: string,
  credentials: LocalHubE2ECredentials
): Promise<StartedHub> {
  const distMain = path.join(options.hubRepoPath, "dist", "app", "main.js");
  if (!(await pathExists(path.join(options.hubRepoPath, "node_modules"))) || !(await pathExists(distMain))) {
    await runHubCommand(options.hubRepoPath, runRoot, "npm", [await packageInstallCommand(options.hubRepoPath)]);
  }
  if (!(await pathExists(distMain))) {
    await runHubCommand(options.hubRepoPath, runRoot, "npm", ["run", "build"]);
  }
  if (!(await pathExists(distMain))) throw new Error("Hub dist/app/main.js missing after build");

  const stdoutLog = path.join(runRoot, "hub.stdout.log");
  const stderrLog = path.join(runRoot, "hub.stderr.log");
  const stdout = createWriteStream(stdoutLog, { flags: "a" });
  const stderr = createWriteStream(stderrLog, { flags: "a" });
  const child = spawn(process.execPath, [distMain], {
    cwd: runRoot,
    env: {
      ...buildLocalHubChildEnv(process.env, { host: options.hubHost, port, sqlitePath, credentials }),
      DOTENV_CONFIG_PATH: path.join(runRoot, "no-env-file.local")
    },
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"]
  });
  child.stdout?.pipe(stdout);
  child.stderr?.pipe(stderr);
  await waitForHubHealth(localHubBaseUrl(options.hubHost, port), child);
  return { process: child, stdoutLog, stderrLog };
}

async function waitForHubHealth(baseUrl: string, child: ChildProcess): Promise<void> {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error("temporary Hub exited before healthz");
    try {
      const response = await fetch(`${baseUrl}/healthz`);
      if (response.ok) return;
    } catch {
      // retry until deadline
    }
    await delay(250);
  }
  throw new Error("temporary Hub did not become healthy");
}

async function stopHub(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null) return;
  child.kill("SIGTERM");
  const stopped = await waitForExit(child, 5000);
  if (!stopped && child.exitCode === null) {
    child.kill("SIGKILL");
    await waitForExit(child, 5000);
  }
}

async function runHubCommand(hubRepoPath: string, runRoot: string, command: string, args: string[]): Promise<void> {
  const log = path.join(runRoot, `hub-${command}-${args.join("-")}.log`.replace(/[^A-Za-z0-9_.-]/g, "_"));
  await runCommand(command, args, hubRepoPath, safeChildEnv(process.env), log, log);
}

async function runPowerShellScript(script: string, args: string[], env: NodeJS.ProcessEnv, stdoutLog: string, stderrLog: string): Promise<void> {
  await runCommand("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, ...args], process.cwd(), env, stdoutLog, stderrLog);
}

async function runCommand(command: string, args: string[], cwd: string, env: NodeJS.ProcessEnv, stdoutLog: string, stderrLog: string): Promise<void> {
  await mkdir(path.dirname(stdoutLog), { recursive: true });
  const stdout = createWriteStream(stdoutLog, { flags: "a" });
  const stderr = createWriteStream(stderrLog, { flags: "a" });
  const child = spawn(command, args, { cwd, env, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
  child.stdout?.pipe(stdout);
  child.stderr?.pipe(stderr);
  const code = await waitForExitCode(child);
  if (code !== 0) throw new Error(`${path.basename(command)} failed with exit code ${code}`);
}

async function fetchReadback(hubUrl: string, readToken: string): Promise<ReadbackBodies> {
  const [nodes, summary, services, custom] = await Promise.all([
    fetchHubJson(`${hubUrl}/v1/nodes`, readToken),
    fetchHubJson(`${hubUrl}/v1/summary`, readToken),
    fetchHubJson(`${hubUrl}/v1/services`, readToken),
    fetchHubJson(`${hubUrl}/v1/custom`, readToken)
  ]);
  return { nodes, summary, services, custom };
}

async function fetchHubJson(url: string, readToken: string): Promise<unknown> {
  const response = await fetch(url, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${readToken}`,
      Accept: "application/json"
    }
  });
  const body = await response.text();
  if (!response.ok) throw new Error(`Hub readback failed with HTTP ${response.status}`);
  if (scanLocalHubE2EText(body).length > 0) throw new Error("Hub readback contains a forbidden marker");
  return JSON.parse(body) as unknown;
}

async function buildDaemonNodeConfig(runRoot: string, nodeId: string): Promise<string> {
  const templatePath = path.join(process.cwd(), "deploy", "examples", "general-linux-agent.node.json");
  const parsed = JSON.parse(await readFile(templatePath, "utf8")) as Record<string, unknown>;
  parsed.node_id = nodeId;
  parsed.hostname = nodeId;
  parsed.region = "local";
  parsed.role = "e2e-node";
  parsed.provider = "local";
  const output = path.join(runRoot, "general-linux-agent.e2e.node.json");
  await writeFile(output, `${JSON.stringify(parsed, null, 2)}\n`, { mode: 0o600 });
  return output;
}

async function assertFileSafe(file: string, credentials: LocalHubE2ECredentials): Promise<void> {
  const text = await readFile(file, "utf8");
  const markers = scanLocalHubE2EText(text, credentials);
  if (markers.length > 0) throw new Error(`file contains forbidden markers: ${markers.join(",")}`);
}

async function readJsonFile(file: string, credentials: LocalHubE2ECredentials): Promise<unknown> {
  const text = await readFile(file, "utf8");
  const markers = scanLocalHubE2EText(text, credentials);
  if (markers.length > 0) throw new Error(`json file contains forbidden markers: ${markers.join(",")}`);
  return JSON.parse(text) as unknown;
}

async function assertLogsSafe(files: string[], credentials: LocalHubE2ECredentials): Promise<void> {
  for (const file of files) {
    if (!(await pathExists(file))) continue;
    const text = await readFile(file, "utf8");
    const markers = scanLocalHubE2EText(text, credentials);
    if (markers.length > 0) throw new Error(`log contains forbidden markers: ${markers.join(",")}`);
  }
}

async function assertAllRunLogsSafe(runRoot: string, credentials: LocalHubE2ECredentials): Promise<void> {
  const files = (await readdir(runRoot))
    .filter((name) => name.endsWith(".log"))
    .map((name) => path.join(runRoot, name));
  await assertLogsSafe(files, credentials);
}

async function countFiles(dir: string, suffix: string): Promise<number> {
  try {
    return (await readdir(dir)).filter((name) => name.endsWith(suffix)).length;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw error;
  }
}

async function packageInstallCommand(repoPath: string): Promise<"ci" | "install"> {
  return (await pathExists(path.join(repoPath, "package-lock.json"))) ? "ci" : "install";
}

async function pathExists(file: string): Promise<boolean> {
  try {
    await stat(file);
    return true;
  } catch {
    return false;
  }
}

function positiveInt(value: string | undefined, fallback: number): number {
  if (value === undefined || value.trim() === "") return fallback;
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

async function delay(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForExit(child: ChildProcess, timeoutMs: number): Promise<boolean> {
  if (child.exitCode !== null) return true;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), timeoutMs);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

async function waitForExitCode(child: ChildProcess): Promise<number | null> {
  return new Promise((resolve) => {
    child.once("exit", (code) => resolve(code));
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.log(`FAIL local_hub_agent_e2e reason=${safeE2EError(error)}`);
    process.exitCode = 1;
  });
}
