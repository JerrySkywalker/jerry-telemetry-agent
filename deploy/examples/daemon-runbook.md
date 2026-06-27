# Generic Server Daemon Runbook

These artifacts are deployment-ready templates only. This goal does not deploy,
start, stop, restart, enable, disable, or edit production services.

Local file-only validation from the repository root:

```powershell
.\scripts\server-agent-daemon.ps1 -Output FileOnly -MaxIterations 2 -IntervalSeconds 1
.\scripts\smoke-server-daemon.ps1
```

HTTP batch mode for a local Hub requires development credentials supplied outside
git and uses Hub `/v1/events/batch`:

```powershell
.\scripts\server-agent-daemon.ps1 -Output Push -HubUrl http://127.0.0.1:3000/v1/events -WriteSecret <dev-secret> -MaxIterations 2
```

The daemon writes safe state and spool files only:

- `STATE_PATH` stores timestamps, event counts, event types, node identity, and
  spool counts.
- `SPOOL_DIR` stores sanitized failed batch payloads without headers,
  signatures, secrets, raw responses, logs, or environment variables.
- `TELEMETRY_SERVER_BATCH_LATEST_FILE` stores the latest sanitized server batch.

The health server is intended for localhost/private use only. Example templates
bind it to `127.0.0.1`.
