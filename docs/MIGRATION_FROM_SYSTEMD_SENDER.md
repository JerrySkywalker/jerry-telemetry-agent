# Migration From Systemd Sender

File mode supports migration from the existing LAX latest JSON flow:

```bash
CODEX_PROVIDER=file
CODEX_STATUS_LATEST_PATH=/input/latest.json
```

Keep the existing systemd sender running until this Docker agent is validated and a cutover is explicitly approved.
