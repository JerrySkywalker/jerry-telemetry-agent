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

The WinSW XML template is a canonical LF byte sequence. Its SHA-256 is over
those raw committed bytes; checkout conversion, CRLF normalization, parsed XML,
or a manifest-provided digest cannot authorize it. `.gitattributes` enforces LF
for workstation XML templates and the lifecycle manager independently rejects
any carriage return before comparing the caller-reviewed trust digest.

## Service account and identity contract

The only supported service account model is `VirtualServiceAccount`, bound
deterministically to `NT SERVICE\JerryTelemetryAgent`. The WinSW template uses
the `NT SERVICE` domain and service-name-derived user, contains no password, and
sets `allowservicelogon=false`; the lifecycle surface neither prompts for a
credential nor grants Service Logon Right. `LocalSystem`, administrator,
network-service, arbitrary existing-account, credential-bearing, and XML
injection inputs fail closed. The account model and a safe binding digest are
recorded in the owner and transaction journals and revalidated on upgrade,
rollback, status, and uninstall.

The owner-selected Agent identity remains configuration, not service-account
state. `node_id` and `TELEMETRY_NODE_KEY_ID` are validated as bounded identifiers
with all LAX markers rejected. A journaled identity-binding digest covers those
two non-secret identifiers plus the external secret-reference binding; it never
contains, reads, or hashes signing material. Status returns only that digest.

Before mutation, the caller independently generates and supplies three
authorization anchors with `Get-AgentWorkstationBindingAnchors.ps1`: combined
config, Agent identity, and external secret-reference bindings. The manager
recalculates them, journals approved and observed values separately, and
rechecks equality during upgrade and rollback.

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

The workstation manager and `Start-AgentRelease.ps1 -ValidateOnly` inspect only
the signing-file reference and filesystem metadata. They never open or hash the
referenced file. Outside fixture mode, manager validation requires an explicit
allow/read rule for the fixed virtual account and rejects write, modify, or full
control for that identity. ACL creation remains a separately authorized
installation prerequisite; this repository does not change ACLs.

The access proof uses a canonical principal allowlist rather than inferred token
membership. Only the exact service SID may supply resource rights. `ALL
SERVICES` is explicitly evaluated for deny precedence and may supply traversal
on ancestors, but it cannot authorize resource writes. SYSTEM and built-in
Administrators remain management principals; grants to every other principal
fail the protected-resource contract.
Release, wrapper, config, and secret resources require read/traverse and reject
write, modify, delete, ACL, or ownership grants. State and output roots allow
create/write without delete. Exact spool and log roots additionally allow child
rename/delete for drain, quarantine, retention, and log rotation, while still
rejecting root delete, ACL, and ownership rights. Every ancestor and protected
sibling remains nonwritable. Every path component and final object must be local
and free of reparse
points, symbolic links, junctions, hardlinks, device/UNC forms, and lexical
traversal. Signing references inside release, config, state, spool, or log
boundaries fail closed.

Mutable-root service ACEs must carry both container-inherit and object-inherit
flags. Validation recursively inspects every existing mutable descendant using
the nearest state/output, spool, or log policy, including inherited deny and
excess-right rejection. Protected siblings are recursively inspected as well;
a safe root cannot hide an independently writable descendant. Fixture ACL
records model inherited child ACEs explicitly. The separate create, quarantine,
unlink, retention, and rotation file-operation rehearsal validates API behavior
only and is not represented as virtual-account ACL evidence.

The owned runtime root is also fail-closed. The lifecycle proof recursively
classifies the owner marker, lock, exact transaction journals, release slots,
config revisions, service-wrapper boundary and leftovers, and mutable data
subtrees. Management metadata is nonwritable to the service identity. Only the
two exact active junctions are exempt from ordinary no-reparse inspection, and
their targets must remain inside the already validated release or config-slot
boundary. Any unclassified runtime-root descendant is rejected; a broad
runtime-root or arbitrary-subtree exemption is not permitted.

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
  -ExpectedServiceTemplateSha256 <APPROVED_RAW_TEMPLATE_SHA256> `
  -ExpectedServiceAccountBindingSha256 <APPROVED_ACCOUNT_BINDING_SHA256> `
  -ExpectedSecretReferenceSchema jerry.workstation.secret-reference.v1 `
  -ExpectedAgentIdentityBindingSha256 <APPROVED_AGENT_IDENTITY_BINDING> `
  -ExpectedConfigBindingSha256 <APPROVED_CONFIG_BINDING> `
  -ExpectedSecretReferenceBindingSha256 <APPROVED_SECRET_REFERENCE_BINDING> `
  -EnvPath <PROTECTED_ENV> -NodeConfigPath <PROTECTED_NODE_CONFIG> -DryRun

# Later production goal only
pwsh -File scripts/workstation/Invoke-AgentWorkstationRuntime.ps1 `
  -Operation Install -RuntimeRoot <PROTECTED_ROOT> `
  -ArtifactPath <ARTIFACT> -ManifestPath <MANIFEST> `
  -ExpectedSourceCommit <FULL_APPROVED_SHA> `
  -ExpectedArtifactSha256 <APPROVED_ARTIFACT_SHA256> `
  -ExpectedServiceTemplateSha256 <APPROVED_RAW_TEMPLATE_SHA256> `
  -ExpectedServiceAccountBindingSha256 <APPROVED_ACCOUNT_BINDING_SHA256> `
  -ExpectedSecretReferenceSchema jerry.workstation.secret-reference.v1 `
  -ExpectedAgentIdentityBindingSha256 <APPROVED_AGENT_IDENTITY_BINDING> `
  -ExpectedConfigBindingSha256 <APPROVED_CONFIG_BINDING> `
  -ExpectedSecretReferenceBindingSha256 <APPROVED_SECRET_REFERENCE_BINDING> `
  -EnvPath <PROTECTED_ENV> -NodeConfigPath <PROTECTED_NODE_CONFIG> `
  -ServiceWrapperPath <PINNED_WINSW> `
  -ServiceAccountModel VirtualServiceAccount `
  -ServiceAccountIdentity 'NT SERVICE\JerryTelemetryAgent' `
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
A persisted first-install journal with no prior pair has a dedicated recovery
path: it verifies the journal-owned candidate identities, removes only slots
recorded as created by that attempt, removes active/service boundaries, preserves
logs, state, spool, and the secret reference, and leaves the owned root
uninstalled and retryable.

Rollback rehashes the complete prior release and exact config revision before
switching, restores the original pair if rollback health fails, and preserves
state, spool, logs, and the secret file without build or package installation.
Production roots carry a component/root-bound ownership marker. Uninstall
refuses unowned roots, removes both active junctions and the service definition,
and preserves releases, config revisions, state, spool, secret files, and WinSW
logs under `logs/agent`. The reviewed service template is digest-pinned and a
caller-supplied production template is rejected.

After install and before later mutation, the manager reads only structured SCM
`StartName` and requires the fixed virtual account. Status exposes only the
verification boolean, never the SCM account value.

`Status` reports only source commit, artifact digest, runtime version, active
slot IDs, spool count, account model/binding digest, Agent identity-binding
digest, and fixed safety booleans. It never prints account identity, config
values, endpoints, ports, secret paths, node identity, headers, or raw evidence.

## Local proof

`npm run smoke:workstation-release` performs fixture-only authorization-anchor
rejection, fixed-entrypoint enforcement, complete dry-run config validation,
install, upgrade, tampered-slot rejection, no-rebuild rollback, exact config
rollback, fresh-install cleanup, failed-upgrade restoration, ownership checks,
synthetic interrupted-first-install recovery plus retry, spool-growth acceptance,
state/spool/secret preservation, status, and uninstall in a random temporary root.
It asserts no real Windows service state or LAX
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
