# Agent Install, Upgrade, And Rollback

The install, upgrade, and uninstall scripts in this repository are dry-run renderers:

```powershell
.\scripts\install-agent-dry-run.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
.\scripts\upgrade-agent-dry-run.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
.\scripts\uninstall-agent-dry-run.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
```

They write plan JSON, command-plan text, and a safety checklist under `.smoke` by default. They do not execute the rendered commands.

Safe deployment phases for a future manually approved deployment:

1. Preflight target prerequisites.
2. Run config doctor against the target config without printing secrets.
3. Build and validate a local package artifact.
4. Render install or upgrade dry-run plans.
5. Run file-only one-shot validation.
6. Run one-shot HTTP upload only after a node secret is manually supplied outside git.
7. Run daemon canary with observation windows.
8. Roll back if health, ingest, spool, or output safety criteria fail.

Rollback criteria:

- Hub ingest fails for the node after upload is enabled.
- Agent health reports repeated HTTP errors.
- Spool count grows across observation windows.
- Safe output scan finds forbidden secret or raw identity markers.
- Health endpoint is exposed beyond the approved interface.

Rollback plan:

- Restore the previous artifact after manual approval.
- Preserve state, spool, config, and secret files by default.
- Do not delete telemetry state unless a separate operator-approved cleanup says so.
- Do not reconfigure LAX fallback runtime as part of a generic server rollback.
