# Old Codex Status Chain Cold Archive

The primary Codex usage telemetry runtime is LAX Docker `jerry-telemetry-agent` using backend usage safe snapshots. The old tmux/status chain is archived and manual fallback only.

Old chain components may include:

- `codex-status-collector`
- `jerry-telemetry-codex-status`
- tmux Codex `/status` capture
- `latest.json`
- `send-latest.sh`
- `codex-status-telemetry.timer`
- `codex-status-telemetry.service`

## Policy

- Do not re-enable `codex-status-telemetry.timer`.
- Do not run old `send-latest.sh` automatically.
- Do not grant the old chain new secrets.
- Do not pipe tmux pane content into logs.
- Do not paste raw old/new status output into chat.
- Do not delete old directories or data during cold archive.
- Do not delete systemd unit files; record present/active/enabled state only.

## Safe Inventory

Run from Windows:

```powershell
.\scripts\diag-old-codex-status-chain-safe.ps1
```

Allowed output:

```text
old_chain_dirs_present=true/false
codex_status_collector_present=true/false
telemetry_codex_status_present=true/false
systemd_timer_unit_present=true/false
systemd_timer_active=active/inactive/not-found
systemd_timer_enabled=enabled/disabled/not-found
service_active=active/inactive/not-found
latest_json_present=true/false
latest_json_mtime=...
send_latest_present=true/false
capture_script_present=true/false
manual_fallback_possible=true/false
secret_markers_printed=false
```

Forbidden output: `latest.json` content, old log content, env content, tokens, token-bearing URLs, `auth.json`, and tmux pane content.

## Archive Runbook

1. Run safe inventory and save only the key/value output.
2. Snapshot file list, sizes, and mtimes only.
3. If a tar archive is needed, write it to a private backup directory only; do not upload it to git.
4. Confirm the timer is inactive/disabled or not-found.
5. Leave old dirs owner-readable only.
6. Record the archive path and fallback procedure.

Cold archive is documentation and backup hygiene, not deletion.
