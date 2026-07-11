# Co-located workstation Agent runtime

## Decision and boundary

MG-44 uses `NATIVE_WINDOWS_SERVICE_RELEASE_SLOTS` for a second, isolated
Telemetry Agent runtime on the Message Gateway workstation. It never reuses or
modifies the LAX Agent, its node identity, its files, or its Docker lifecycle.

The workstation Agent is a WinSW-managed Windows service with an immutable,
digest-verified release, bundled Node 22 runtime, external protected config and
secret reference, persistent state/spool, and no-rebuild rollback. Gateway and
Agent are co-located; the Message Gateway collector and Agent health listener
are loopback-only and introduce no public port.

This repository commits no WinSW/Node binary, archive, secret, endpoint value,
identity value, or machine path. `deploy/workstation/trusted-runtime.json` pins
WinSW x64 `2.12.0` (MIT) and Node `22.23.1` Windows x64 by exact SHA-256.
Digest, provenance, license, version, or architecture mismatch fails closed.

## Artifact

`scripts/workstation/New-AgentWorkstationRelease.ps1` requires a clean exact
commit and the pinned official Node archive. It performs `npm ci` and build only
in a temporary trusted builder tree, then emits:

```text
jerry-telemetry-agent-<version>-<full-commit>-win-x64-node22.zip
<artifact>.manifest.json
```

The artifact contains portable `node.exe`, compiled `dist/**`, package metadata,
the fail-closed launcher, and independent verifier. It has no runtime npm
dependency, node_modules, source, tests, environment, node config, secret,
state, spool, logs, backup, or machine-specific file.

The `jerry.workstation.release.v1` manifest records exact source and artifact
identity, per-file SHA-256, runtime/build versions, required configuration key
names, inactive defaults, collector/event bindings, and preservation rules.
It records no secret value, endpoint, hostname, user ID, or machine path.

## Protected layout

```text
manager/
services/agent/
releases/agent/<commit>-<digest>/
active/agent
config/agent/revisions/<combined-config-digest>/agent.env
config/agent/revisions/<combined-config-digest>/node.json
config/agent/active
secrets/agent/hub-signing-secret
state/agent/agent-state.json
state/agent/server-batch.latest.safe.json
state/agent/spool/
logs/agent/
transactions/agent-current.json
```

Releases are immutable. Config revisions contain names and non-secret settings;
the signing value is outside them and loaded only through the absolute
`TELEMETRY_NODE_SECRET_FILE` reference. The service identity needs read access
to that single file, read access to release/config, and write access only to its
state/spool/log roots. ACL proof and the real identity remain later owner/read-
only-production evidence.

The config doctor reports only secret-source presence booleans. It never reads
the secret file for diagnosis. Runtime rejects a simultaneous direct secret and
secret-file reference, remote/relative secret paths, missing files, and multi-
line values.

## Safe defaults

- `message-gateway-readiness` exists exactly once and starts `enabled=false`.
- Initial `TELEMETRY_OUTPUT_MODE=file`; HTTP upload activation is separate.
- Node identity must be workstation-specific and must not reuse `us-lax-pro-01`.
- Gateway target is HTTP loopback only, redirects are manual/rejected, and the
  collector timeout is at most 2000 ms.
- Agent health binds to loopback. A source default no longer binds broadly.
- Hub uploads have a positive bounded timeout, default 5000 ms and maximum
  30000 ms.
- State/spool/latest files and secret references must be absolute and external
  to release slots.
- Service dependency is Gateway-first for start and Agent-first for rollback.

## Lifecycle

`Invoke-AgentWorkstationRuntime.ps1` supports `Install`, `Upgrade`, `Rollback`,
`Uninstall`, and `Status`. Mutation verbs require exactly one `-DryRun` or the
matching confirmation switch. Outside fixture mode, they also require an owner
authorization ID, elevated context, explicit protected parameters, and the
digest-matching WinSW binary.

```powershell
# Read-only plan
pwsh -File scripts/workstation/Invoke-AgentWorkstationRuntime.ps1 `
  -Operation Install -RuntimeRoot <PROTECTED_ROOT> `
  -ArtifactPath <ARTIFACT> -ManifestPath <MANIFEST> `
  -ExpectedSourceCommit <FULL_APPROVED_SHA> `
  -ExpectedArtifactSha256 <APPROVED_ARTIFACT_SHA256> `
  -EnvPath <PROTECTED_ENV> -NodeConfigPath <PROTECTED_NODE_CONFIG> -DryRun

# Later production goal only
pwsh -File scripts/workstation/Invoke-AgentWorkstationRuntime.ps1 `
  -Operation Install -RuntimeRoot <PROTECTED_ROOT> `
  -ArtifactPath <ARTIFACT> -ManifestPath <MANIFEST> `
  -ExpectedSourceCommit <FULL_APPROVED_SHA> `
  -ExpectedArtifactSha256 <APPROVED_ARTIFACT_SHA256> `
  -EnvPath <PROTECTED_ENV> -NodeConfigPath <PROTECTED_NODE_CONFIG> `
  -ServiceWrapperPath <PINNED_WINSW> `
  -AuthorizationId <OWNER_AUTHORIZATION> -ConfirmInstall
```

The expected source and artifact digests are caller-supplied authorization
anchors; the manifest cannot authorize itself. Verification also pins the
platform, Node archive, wrapper, fixed inventoried entrypoint, collector/event
binding, preservation flags, and absence of production Git/npm/build.

Install/upgrade verifies before and after extraction, runs complete launch and
protected-config validation without starting Node, and snapshots both config
files by their combined digest. A pending journal is written before service or
junction mutation. Activation advances through stop, release switch, config
switch, start, loopback health, and a no-spool-growth gate. Failed upgrade
restores and revalidates the prior pair; failed fresh install removes both active
junctions, the service boundary, and newly created candidate slots. Interrupted
activation blocks later mutation and is recoverable through confirmed rollback.

Rollback rehashes the complete prior release and exact config revision before
switching, restores the original pair if rollback health fails, and preserves
state, spool, logs, and the secret file without build or package installation.
Production roots carry a component/root-bound ownership marker. Uninstall
refuses unowned roots, removes both active junctions and the service definition,
and preserves releases, config revisions, state, spool, secret files, and WinSW
logs under `logs/agent`. The reviewed service template is digest-pinned and a
caller-supplied production template is rejected.

`Status` reports only source commit, artifact digest, runtime version, active
slot IDs, and spool count. It never prints config values, endpoints, secret
paths, node identity, headers, or raw evidence.

## Local proof

`npm run smoke:workstation-release` performs fixture-only authorization-anchor
rejection, fixed-entrypoint enforcement, complete dry-run config validation,
install, upgrade, tampered-slot rejection, no-rebuild rollback, exact config
rollback, fresh-install cleanup, failed-upgrade restoration, ownership checks,
spool-growth acceptance, state/spool/secret preservation, status, and uninstall
in a random temporary root. It asserts no real Windows service state or LAX
runtime changes.

`scripts/workstation/Test-ColocatedGatewayAgentIntegration.ps1` accepts already
verified exact-commit Gateway and Agent artifacts. It extracts them into a
random temporary root, boots Gateway and Agent from their bundled Node 22
runtimes on dynamically allocated loopback ports, proves the collector emits
nothing while disabled, then enables only a fixture node config and verifies a
signed batch against a fixture-only mock Hub receiver. It asserts manifest
identity, both listeners are loopback-only, `not_configured`, the exact envelope
and readiness schema, specialized source/collector identity, TTL 300, exact
Gateway version, zero spool, no secret/log marker, released ports, stopped
processes, and removed fixture directories.

MG-44P0A does not access production, use SSH, register a service, install WinSW,
deploy a runtime, enable the collector, enable HTTP upload, read a real secret,
or modify Hub configuration.
