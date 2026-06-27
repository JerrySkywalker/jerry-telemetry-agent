# Deploy Examples

These files are placeholder-only examples for local validation and future server packaging.

- `general-linux-agent.node.json` enables Linux node info, resources, HTTP/TCP probes, Docker read-only status, systemd read-only status, custom JSON, and agent health.
- `general-linux-agent.env.example` defaults to file output and keeps HTTP upload disabled unless a development secret is supplied outside git.
- `general-linux-docker-compose.yml.example` is an example shape only. Do not run it for production deployment from this goal.
- `general-linux-daemon.env.example` configures the generic server daemon in file-only mode by default.
- `general-linux-daemon.compose.yml.example` is a daemon compose template with localhost-bound health.
- `general-linux-systemd.service.example` is a service unit template only. Do not install or enable it from this goal.
- `agent-deployment-manifest.example.json` describes a placeholder deployment manifest with HTTP upload disabled by default.
- `general-linux-install-plan.example.json`, `general-linux-upgrade-plan.example.json`, and `general-linux-uninstall-plan.example.json` show the dry-run plan shape rendered by the deployment scripts.
- `daemon-runbook.md` documents local daemon validation and safe HTTP batch mode.
- `custom/example.safe.json` is synthetic fixture data for the custom-json collector.

The Docker and systemd collectors are read-only status collectors. The agent does not start, stop, restart, enable, disable, or edit services.

Deployment-readiness scripts render local plans under `.smoke` only:

```powershell
.\scripts\doctor-agent-config.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
.\scripts\install-agent-dry-run.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
.\scripts\upgrade-agent-dry-run.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
.\scripts\uninstall-agent-dry-run.ps1 -NodeConfigPath .\deploy\examples\general-linux-agent.node.json
.\scripts\package-agent-local.ps1
```

These commands do not deploy, SSH, copy to servers, start services, stop services, or render real secret values.
