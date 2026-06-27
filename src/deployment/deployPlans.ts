import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import packageJson from "../../package.json" with { type: "json" };
import { parseDeclarativeNodeConfig } from "../collectors/registry.js";
import { findForbiddenTelemetryMarkers } from "../telemetry/forbiddenMarkers.js";

export type DeploymentPlanAction = "install" | "upgrade" | "uninstall";

export interface DeploymentPlanOptions {
  action: DeploymentPlanAction;
  nodeConfigPath: string;
  envExamplePath?: string;
  installRoot?: string;
  stateDir?: string;
  logDir?: string;
  user?: string;
  outputDir?: string;
}

export interface DeploymentPlan {
  action: DeploymentPlanAction;
  generated_at: string;
  dry_run_only: true;
  production_mutation: false;
  package_version: string;
  node: {
    node_id: string;
    hostname: string;
    region: string;
    role: string;
    collectors_count: number;
  };
  inputs: {
    node_config_present: boolean;
    env_example_present: boolean;
  };
  paths: {
    install_root: string;
    state_dir: string;
    log_dir: string;
    systemd_unit_path: string;
  };
  expected_directories: string[];
  expected_files: string[];
  command_plan: string[];
  safety_checklist: string[];
  upgrade?: {
    current_version: string;
    target_version: string;
    backup_plan: string[];
    config_preserve_plan: string[];
    state_preserve_plan: string[];
    smoke_plan: string[];
    rollback_plan: string[];
  };
  uninstall?: {
    stop_disable_plan: string[];
    preserve_state_by_default: true;
    remove_app_files_requires_manual_approval: true;
    remove_systemd_unit_plan: string[];
    secret_deletion: "never_by_default";
  };
  safe: {
    secret_values_rendered: false;
    env_file_rendered: false;
    mutating_commands_executed: false;
    forbidden_markers_found: string[];
  };
}

export function buildDeploymentPlan(options: DeploymentPlanOptions): DeploymentPlan {
  const installRoot = options.installRoot ?? "/opt/jerry-telemetry-agent";
  const stateDir = options.stateDir ?? "/var/lib/jerry-telemetry-agent";
  const logDir = options.logDir ?? "/var/log/jerry-telemetry-agent";
  const user = options.user ?? "telemetry-agent";
  const nodeConfig = readNodeConfig(options.nodeConfigPath);
  const node = {
    node_id: nodeConfig.node_id ?? "unknown",
    hostname: nodeConfig.hostname ?? nodeConfig.node_id ?? "unknown",
    region: nodeConfig.region ?? "unknown",
    role: nodeConfig.role ?? "general-linux-node",
    collectors_count: nodeConfig.collectors?.filter((collector) => collector.enabled).length ?? 0
  };

  const base: DeploymentPlan = {
    action: options.action,
    generated_at: new Date().toISOString(),
    dry_run_only: true,
    production_mutation: false,
    package_version: packageJson.version,
    node,
    inputs: {
      node_config_present: existsSync(path.resolve(options.nodeConfigPath)),
      env_example_present: options.envExamplePath ? existsSync(path.resolve(options.envExamplePath)) : false
    },
    paths: {
      install_root: installRoot,
      state_dir: stateDir,
      log_dir: logDir,
      systemd_unit_path: "/etc/systemd/system/jerry-telemetry-agent.service"
    },
    expected_directories: [installRoot, stateDir, logDir, `${installRoot}/config`, `${stateDir}/spool`],
    expected_files: [
      `${installRoot}/package.json`,
      `${installRoot}/dist/src/server-agent-daemon.js`,
      `${installRoot}/deploy/examples/general-linux-agent.node.json`,
      `${installRoot}/deploy/examples/general-linux-daemon.env.example`
    ],
    command_plan: baseCommandPlan(options.action, installRoot, stateDir, logDir, user),
    safety_checklist: [
      "Manual approval is required before production deployment.",
      "Dry-run scripts render plans only and do not SSH or mutate services.",
      "TELEMETRY_NODE_SECRET must be supplied outside git and is reported only as present or missing.",
      "Health endpoints must remain localhost or private-interface bound.",
      "Run release-gate-local.ps1 and package-agent-local.ps1 before any manual deployment."
    ],
    safe: {
      secret_values_rendered: false,
      env_file_rendered: false,
      mutating_commands_executed: false,
      forbidden_markers_found: []
    }
  };

  if (options.action === "upgrade") {
    base.upgrade = {
      current_version: "unknown-render-only",
      target_version: packageJson.version,
      backup_plan: [
        `Plan backup of ${installRoot} to a timestamped operator-selected path.`,
        `Plan backup of configuration under ${installRoot}/config without printing secret files.`
      ],
      config_preserve_plan: ["Preserve node config and env files in place.", "Never render a real .env with secret values."],
      state_preserve_plan: [`Preserve ${stateDir} and ${stateDir}/spool.`],
      smoke_plan: [
        "Render docker compose config.",
        "Run server-agent-once in FileOnly mode.",
        "Run bounded server-agent-daemon in FileOnly mode."
      ],
      rollback_plan: [
        "Restore previous artifact and config backup after manual approval.",
        "Keep state and secrets untouched unless an operator explicitly changes them."
      ]
    };
  }

  if (options.action === "uninstall") {
    base.uninstall = {
      stop_disable_plan: ["Plan service stop.", "Plan service disable."],
      preserve_state_by_default: true,
      remove_app_files_requires_manual_approval: true,
      remove_systemd_unit_plan: ["Plan systemd unit removal after service is stopped and disabled."],
      secret_deletion: "never_by_default"
    };
  }

  const forbidden = findForbiddenTelemetryMarkers(base);
  return {
    ...base,
    safe: {
      ...base.safe,
      forbidden_markers_found: forbidden
    }
  };
}

function readNodeConfig(file: string) {
  if (!existsSync(path.resolve(file))) throw new Error("NodeConfigPath does not exist");
  return parseDeclarativeNodeConfig(JSON.parse(readFileSync(file, "utf8")) as unknown);
}

function baseCommandPlan(action: DeploymentPlanAction, installRoot: string, stateDir: string, logDir: string, user: string): string[] {
  const prefix = "PLAN ONLY - not executed:";
  if (action === "install") {
    return [
      `${prefix} create user ${user}`,
      `${prefix} create directories ${installRoot}, ${stateDir}, ${logDir}`,
      `${prefix} copy validated artifact into ${installRoot}`,
      `${prefix} write systemd unit at /etc/systemd/system/jerry-telemetry-agent.service`,
      `${prefix} run docker compose config`,
      `${prefix} run one-shot FileOnly smoke`,
      `${prefix} wait for manual approval before any service start`
    ];
  }
  if (action === "upgrade") {
    return [
      `${prefix} identify currently installed version`,
      `${prefix} backup app and config paths`,
      `${prefix} stop service after manual approval`,
      `${prefix} install validated artifact`,
      `${prefix} preserve config, state, spool, and secret files`,
      `${prefix} run FileOnly smoke before enabling HTTP output`,
      `${prefix} use rollback plan if smoke fails`
    ];
  }
  return [
    `${prefix} stop service after manual approval`,
    `${prefix} disable service after manual approval`,
    `${prefix} preserve ${stateDir} by default`,
    `${prefix} remove app files only after explicit approval`,
    `${prefix} remove systemd unit only after explicit approval`,
    `${prefix} never delete secret or state files by default`
  ];
}
