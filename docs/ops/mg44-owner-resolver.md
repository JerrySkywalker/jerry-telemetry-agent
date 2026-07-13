# MG-44 owner resolver

`scripts/workstation/Resolve-Mg44Owner.ps1` owns the non-secret workstation
boundary used by the MG-44 co-located Gateway and Agent runtime. It is an
operations tool, not part of a release slot and not a secret resolver.

The production boundary is derived from the owner-approved safe identifier
`workstation-mg44-01` below the canonical ProgramData MG-44 root. The resolver
stores the private path, service, and loopback bindings in a protected JSON
file, but command output contains only safe identifiers, booleans, receipt
IDs, and classifications.

Supported actions:

- `Inspect`: read-only state classification.
- `Plan`: read-only safe-ID plan; never authorizes secret generation.
- `Apply`: create the non-secret parent, sibling Gateway/Agent roots, Agent
  identity directory, empty protected secret directory, and resolver.
- `Status`: repeatable integrity, ACL, mapping, lock, temp-file, and port
  status.
- `Repair`: repair corrupt or unsafe resolver state and stale transaction-owned
  temp files. A valid resolver with owner-mapping drift is rejected.

The resolver uses a unique write-through temp file, protected temp ACL, and
same-directory atomic replacement. A failure before replacement leaves a
transaction-owned temp marker for `Status`/`Repair`; it does not delete a
valid resolver or non-secret scaffolding. The secret directory is created
empty and remains empty until the separate identity transaction writes the
protected signing reference.

Example local fixture gate:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/workstation/Test-Mg44OwnerResolver.ps1
```

The fixture covers creation, idempotent re-entry, schema/JSON repair, broad
ACL rejection, atomic replacement, interrupted temp/ACL recovery, mapping-drift
rejection, and retention after simulated secret compensation. It never
generates or reads a secret.

Production bootstrap must run `Plan`, verify its safe receipt, then run one
`Apply` under the authorized administrator session. Repeat `Status` after
bootstrap and before identity preflight. Do not pass a secret, secret hash, or
private mapping on the command line.
