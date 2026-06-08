# Migration From Systemd Sender

The current LAX systemd capture and sender path stays active until a manual production cutover is explicitly approved. Goal 004 prepares validation only; it does not deploy, stop timers, or change the production telemetry hub.

## Phases

1. Keep the current systemd capture and send timer unchanged.
2. Run backend usage local smoke on Windows:

```powershell
scripts/smoke-codex-backend-usage-local.ps1
```

3. Run LAX preflight:

```powershell
scripts/lax-backend-usage-preflight.ps1
```

4. Deploy the agent on LAX only in dry-run or file-only mode after manual approval for that host action. Do not include `http` in `TELEMETRY_OUTPUT_MODE` for the first container run.
5. Run the agent once with HTTP sink using a test `TELEMETRY_NODE_ID` if needed, after confirming the target hub route and node secret manually.
6. Compare telemetry hub output against the old sender output.
7. Only after the backend usage path is stable, change the old timer to capture-only or disable it.
8. Do not remove the old fallback until backend usage has been stable for several days.

## Fallback File Mode

File mode remains available for migration fallback from the existing LAX latest JSON flow:

```bash
CODEX_PROVIDER=file
CODEX_STATUS_LATEST_PATH=/input/latest.json
TELEMETRY_COLLECTOR_MODE=codex-cli-status-fallback
```
