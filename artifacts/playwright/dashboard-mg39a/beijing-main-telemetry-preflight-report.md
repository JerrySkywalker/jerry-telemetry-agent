# MG-39A Beijing Main Telemetry Producer Preflight

## Scope

- working_repo: `jerry-telemetry-agent`
- node_id: `beijing-main-01`
- hostname: `tencent-pek-01`
- region: `cn-beijing`
- production_touched: `false`
- beijing_touched: `read_only`
- hub_touched: `read_only_no_mutation`
- dashboard_deployed: `false`
- agent_deployed: `false`
- secrets_visible: `false`

This report is a preflight and deployment plan only. No production deployment,
Hub deployment, Agent deployment, service restart, container restart, Beijing
file edit, Hub `.env` mutation, LAX mutation, Dashboard deployment, 1Panel
change, Cloudflare/DNS change, Authelia change, or OpenResty change was
performed.

## Local Preflight

- git_fetch_origin_prune: `pass`
- git_checkout_main: `pass`
- git_pull_ff_only_origin_main: `pass`
- base_commit: `13b0cb068c47bffeacecac842e52ef1971175df5`
- git_status_short: `dirty_untracked_preexisting`
- untracked_groups: `..smoke`, `artifacts`, `fixtures/readmodel`
- npm_run_typecheck: `pass`
- npm_test: `pass`
- npm_test_files: `30 passed`
- npm_test_cases: `156 passed`
- npm_run_build: `pass`
- git_diff_check: `pass`
- validate_local: `pass`
- scan_secrets_light: `pass`
- release_gate_local: `pass`

## Source Audit

- generic_server_agent_supported: `true`
- node_snapshot_supported: `true`
- node_resources_supported: `true`
- service_health_supported: `true`
- docker_containers_supported: `true`
- systemd_units_supported: `true`
- http_probe_supported: `true`
- batch_hub_upload_supported: `true`
- install_dry_run_supported: `true`
- rollback_plan_supported: `true`

Evidence:

- `deploy/examples/general-linux-agent.node.json` defines the generic Linux
  collector shape.
- `docs/PROVIDERS.md` documents allowlisted collectors and explicitly rejects
  arbitrary shell command collectors.
- `src/collectors/registry.ts` maps collector names to event families and fails
  closed on unknown names.
- `src/collectors/serverBatch.ts` emits Hub-compatible v1 batches.
- `scripts/server-agent-once.ps1`, `scripts/server-agent-daemon.ps1`,
  `scripts/doctor-agent-config.ps1`, `scripts/install-agent-dry-run.ps1`,
  `scripts/upgrade-agent-dry-run.ps1`, and `scripts/package-agent-local.ps1`
  are present and exercised by the local gates.

## Beijing Read-Only Host Inventory

- ssh_beijing_used: `true`
- beijing_hostname: `tencent-pek-01`
- beijing_os: `Linux 6.8.0-124-generic x86_64 GNU/Linux`
- beijing_docker_running: `true`
- beijing_hub_container_running: `true`
- beijing_dashboard_container_running: `true`
- beijing_openresty_running: `true`
- beijing_authelia_running: `true`
- beijing_halo_running: `true`
- beijing_hermes_running: `true`
- beijing_message_gateway_running: `false`
- beijing_local_hub_healthz_status: `200`
- beijing_dashboard_health_status: `root_200_healthz_404`
- beijing_openresty_local_root_status: `200`
- beijing_candidate_services: `docker.service,jerry-telemetry-hub-canary-reverse-tunnel.service,jerry-telemetry-hub-canary.service`
- beijing_listening_ports_checked: `true`

Only coarse booleans, command availability, service names, local port numbers,
and HTTP status codes were recorded. No environment values, raw logs, raw
payloads, database rows, token values, or secret material were printed.

## Planned Node Config

- beijing_config_path: `deploy/examples/beijing-main-agent.node.json`
- beijing_config_valid: `true`
- provider: `tencent-cloud`
- role: `main-hub-dashboard`

Collectors:

- `node-info`
- `node-resources`
- `service-health`
- `http-probe`
- `docker-containers`
- `systemd-units`
- `custom-json`
- `agent-health`

Service targets:

- `telemetry-hub-healthz`: `http://127.0.0.1:3000/healthz`, expected `200`
- `glance-dashboard-root`: `http://127.0.0.1:18090/`, expected `200`
- `openresty-root`: `http://127.0.0.1/`, expected `200`
- `authelia`: `planned_endpoint_unknown`
- `hermes`: `planned_endpoint_unknown`
- `message-gateway`: `not_present_in_read_only_inventory`

Docker allowlist:

- `*telemetry-hub*`
- `*jerry-glance-dashboard*`
- `*openresty*`
- `*authelia*`
- `*hermes*`

Systemd unit list:

- `docker.service`
- `jerry-telemetry-hub-canary.service`
- `jerry-telemetry-hub-canary-reverse-tunnel.service`

No arbitrary command collectors are configured.

## Hub Write-Secret Readiness

- hub_accepts_beijing_main_node_write: `false`
- beijing_main_write_secret_present: `false`
- beijing_main_key_rotation_needed: `false`
- hub_secret_mutation_needed: `true`

Read-only metadata showed the production Hub `.env` file exists and contains a
node-secret configuration key. It mentions `us-lax-pro-01` but does not mention
`beijing-main-01`. Secret values were not printed or hashed.

Because the Beijing write secret is absent, no upload attempt was made.

## Local File-Only Smoke

- doctor_agent_config: `pass`
- beijing_config_valid: `true`
- server_agent_once_file_only: `pass`
- local_file_only_batch_written: `true`
- local_file_only_event_families: `node.snapshot,node.resources.snapshot,service.health.snapshot,docker.containers.snapshot,systemd.units.snapshot,custom.snapshot,telemetry.agent.health`
- local_file_only_secret_scan_pass: `true`
- smoke_server_agent: `pass`
- upload_attempted: `false`

The local file-only smoke wrote `.smoke/beijing-main.batch.safe.json` and the
smoke wrapper wrote `.smoke/beijing-main.smoke.batch.safe.json`. Both reported
`forbidden_markers_found=false`.

## Install And Upgrade Dry-Run

- install_dry_run_passed: `true`
- upgrade_dry_run_passed: `true`
- package_agent_local_passed: `true`
- planned_remote_root: `/opt/jerry-telemetry-agent`
- planned_state_dir: `/var/lib/jerry-telemetry-agent`
- planned_log_dir: `/var/log/jerry-telemetry-agent`
- planned_service_mode: `systemd_daemon`
- planned_backup_path_pattern: `timestamped operator-selected backup of /opt/jerry-telemetry-agent and config`
- planned_rollback_available: `true`

The dry-run scripts rendered plans only. They did not SSH, copy files, start,
stop, restart, enable, disable, or mutate production services.

## Production Hub Readback Baseline

- prod_healthz_status: `200`
- prod_read_token_available: `true`
- prod_fleet_status: `not_verified_auth_failed_401`
- prod_fleet_beijing_main_status: `not_found_after_401`
- prod_fleet_beijing_not_instrumented: `not_verified_auth_failed_401`
- prod_fleet_lax_online: `not_verified_auth_failed_401`
- prod_pipeline_status: `not_verified_auth_failed_401`
- prod_nodes_status: `not_verified_auth_failed_401`
- prod_summary_status: `not_verified_auth_failed_401`

`/healthz` returned `200`. A dashboard-side read token was available and used in
memory only, without printing the token or raw bodies, but `/v1/fleet/overview`,
`/v1/pipelines/overview`, `/v1/nodes`, and `/v1/summary` still returned `401`.
The MG-38P baseline supplied with the goal remains the last successful readback
context.

## Deployment Readiness Classification

- beijing_agent_deployment_ready: `false`
- hub_secret_ready: `false`
- beijing_service_targets_ready: `false`
- beijing_config_ready: `true`

Blocking gaps:

- Production Hub write secret for `beijing-main-01` is not present.
- Authelia and Hermes local health endpoints were not established by read-only
  inventory, so they remain planned rather than configured as probes.
- Production read-model readback could not be refreshed without a safe read
  token accepted by the current read-model endpoints.

Next recommended goal:

- `MG-39S authorized Hub node-secret registration for beijing-main-01`
