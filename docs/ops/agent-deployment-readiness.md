# Agent Deployment Readiness

This repository is deployment-ready only after local checks pass and an operator grants separate manual approval for a real target. This goal does not deploy the agent.

Required local checks:

```powershell
.\scripts\release-gate-local.ps1
.\scripts\package-agent-local.ps1
.\scripts\doctor-agent-config.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
.\scripts\smoke-server-daemon.ps1
.\scripts\smoke-local-hub-agent-e2e.ps1 -Mode Once
.\scripts\smoke-local-hub-agent-e2e.ps1 -Mode Daemon
```

If the sibling Hub repository is not available, the local Hub E2E smoke may skip with an explicit reason. A skip is acceptable for local packaging readiness, but a controlled deployment should run the E2E smoke before any server change.

Server prerequisites:

- Docker.
- Docker Compose for Compose deployment.
- Node.js only for a non-Docker deployment.
- A writable state directory.
- A writable log directory.
- A local config directory.
- A localhost or private-interface health port.
- Outbound reachability to the Hub endpoint only when HTTP upload is enabled.

Safety boundaries:

- Manual approval is required before production deployment.
- The dry-run scripts render plans only.
- The package script writes local artifacts only.
- No script in this readiness flow stops services, starts services, restarts services, SSHs, copies files to a server, or changes production runtime.
- LAX Codex daemon behavior remains separate and untouched.
