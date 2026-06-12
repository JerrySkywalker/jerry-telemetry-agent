# LAX Agent Safe Diagnostics

Use:

```powershell
.\scripts\diag-lax-agent-safe.ps1
```

The script copies a temporary shell probe to LAX and removes it after execution. It reports only booleans, mtimes, counts, status values, and marker presence.

Expected healthy MG020R baseline:

```text
healthz_18081_ok=true
usage_marker_present=false
health_marker_present=false
state_marker_present=false
spool_count=0
raw_backend_printed=false
auth_json_printed=false
```

The script must not print:

- `.env` values
- Codex `auth.json`
- access, refresh, or id tokens
- raw backend responses
- raw state JSON
- spool payloads
- account ids, user ids, email, referral, or promo fields

If `usage_file_exists=false` but `health_file_exists=true`, diagnose collector output separately from health reporting. Do not infer production failure from one state file without checking healthz, spool count, marker presence, and mtimes together.
