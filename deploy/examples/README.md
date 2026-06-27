# Deploy Examples

These files are placeholder-only examples for local validation and future server packaging.

- `general-linux-agent.node.json` enables Linux node info, resources, HTTP/TCP probes, Docker read-only status, systemd read-only status, custom JSON, and agent health.
- `general-linux-agent.env.example` defaults to file output and keeps HTTP upload disabled unless a development secret is supplied outside git.
- `general-linux-docker-compose.yml.example` is an example shape only. Do not run it for production deployment from this goal.
- `general-linux-daemon.env.example` configures the generic server daemon in file-only mode by default.
- `general-linux-daemon.compose.yml.example` is a daemon compose template with localhost-bound health.
- `general-linux-systemd.service.example` is a service unit template only. Do not install or enable it from this goal.
- `daemon-runbook.md` documents local daemon validation and safe HTTP batch mode.
- `custom/example.safe.json` is synthetic fixture data for the custom-json collector.

The Docker and systemd collectors are read-only status collectors. The agent does not start, stop, restart, enable, disable, or edit services.
