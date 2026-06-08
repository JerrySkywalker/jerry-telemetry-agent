# Goal 005: Fix real backend usage collector and prepare LAX backend dry-run

We are in YOLO development mode. Use the repository's PR automation policy.

## Current state

The backend usage collector has been implemented and merged to main.

Local validation passes:
- npm install
- npm run typecheck
- npm test
- npm run build
- docker compose config
- validate-local
- scan-secrets-light

But real local backend usage smoke currently returns:

- status_ok=False
- limits_count=0

Manual safe auth inspection shows:

- auth.json exists
- auth.json is non-empty
- auth.json top-level fields:
  - OPENAI_API_KEY
  - auth_mode
  - last_refresh
  - tokens
- auth.json tokens object contains:
  - access_token
  - account_id
  - id_token
  - refresh_token

Do not print or commit token values.

## Goal

Make the backend usage collector work against the real local Codex ChatGPT auth state.

Success criteria:

- scripts/smoke-codex-backend-usage-local.ps1 returns status_ok=True
- limits_count > 0
- default limit is detected when present
- GPT-5.3-Codex-Spark additional limit is detected when present
- output snapshot contains no access_token, refresh_token, email, account_id, user_id, referral_beacon, promo, or raw response
- local safe file is written to an ignored path
- no upload to production hub during local smoke

Do not deploy to LAX.
Do not stop or modify the current LAX systemd timer.
Do not modify production telemetry hub.
Do not commit real secrets.

## Tasks

### 1. Diagnose failure path

Inspect:

- scripts/smoke-codex-backend-usage-local.ps1
- src/collectors/codex/auth-provider.ts
- src/collectors/codex/usage-client.ts
- src/collectors/codex/normalizer.ts
- src/collectors/codex/index.ts
- src/main.ts
- src/config.ts

Determine whether failure is:

- auth_json_missing
- access_token_missing
- wrong CODEX_HOME on Windows
- auth.json schema mismatch
- bad Authorization header
- missing request headers
- http_401
- http_403
- http_404
- http_429
- http_5xx
- network_error
- schema_error
- output path issue

Do not print auth.json or token values.

### 2. Fix auth provider

Support current observed Codex auth schema:

```json
{
  "OPENAI_API_KEY": null,
  "auth_mode": "...",
  "last_refresh": "...",
  "tokens": {
    "access_token": "...",
    "account_id": "...",
    "id_token": "...",
    "refresh_token": "..."
  }
}
Requirements:

Support tokens.access_token.
Keep any existing supported schema if present.
Do not return account_id unless explicitly represented as redacted/omitted metadata.
Do not log access_token, refresh_token, id_token, account_id.
Add tests using redacted/fake fixture only.
3. Fix Windows CODEX_HOME handling

Ensure Windows default is:

%USERPROFILE%\.codex

and explicit env works:

CODEX_HOME=C:\Users\jerry.codex

Add tests for:

Windows default path construction if practical
explicit CODEX_HOME path
missing auth.json
auth.json without tokens.access_token
4. Fix usage client

Default endpoint remains:

https://chatgpt.com/backend-api/wham/usage

Do not switch to:

https://chatgpt.com/backend-api/codex/usage

Requirements:

Use Authorization Bearer access_token.
Add appropriate Accept/User-Agent headers.
Add timeout.
Produce safe diagnostics:
endpoint family
HTTP status
error_code
no header/token values
Map:
401 -> http_401
403 -> http_403
404 -> http_404
429 -> http_429
5xx -> http_5xx
network -> network_error
5. Improve normalizer

Ensure it handles the verified wham/usage shape:

rate_limit
additional_rate_limits
credits
spend_control
plan_type
rate_limit_reached_type
rate_limit_reset_credits if useful

Mapping:

raw.rate_limit -> limits[0], scope=default, name=default
raw.additional_rate_limits[] -> scope=additional
used_percent -> used_percent
remaining_percent = 100 - used_percent
limit_window_seconds -> window_seconds
reset_at -> reset_at_epoch and reset_at_iso
plan_type -> account.plan_type
credits -> credits
spend_control -> spend_control

Never include:

email
account_id
user_id
referral_beacon
promo
raw response
6. Improve smoke script diagnostics

Update scripts/smoke-codex-backend-usage-local.ps1.

It should print only safe diagnostics:

auth_file_exists=True/False
auth_file_length
auth_mode if available
has_access_token=True/False
endpoint
output snapshot path
status_ok
error_code
message
limits_count
default_limit_found
spark_limit_found
raw_omitted_keys

It must not print:

auth.json raw content
access_token
refresh_token
id_token
account_id
email
user_id
7. Add a direct safe backend probe mode if useful

Optionally add:

npm run smoke:codex-backend

or document the PowerShell smoke command.

It should not upload to telemetry hub.

8. Last-good behavior

If real backend request succeeds:

write latest safe snapshot
write last-good safe snapshot
status.ok=true

If it fails:

write error snapshot
if last-good exists, status.stale=true
preserve last-good

Add tests for this behavior.

9. Glance summary

Ensure summary generation works from the successful snapshot.

It should include:

ok
stale
node_id
plan_type
default_limit primary/secondary used and remaining percent
reset_after_seconds
reset_at_iso
additional limits
credits summary
spend_control summary
observed_at
10. LAX backend usage preflight

Improve or add:

scripts/lax-backend-usage-preflight.ps1

It should safely check:

SSH lax works
Docker exists
Docker Compose exists
host codex exists
host ~/.codex/auth.json exists
auth.json has tokens.access_token without printing it
current old codex-status-telemetry.timer status
telemetry hub healthz
latest codex.status endpoint
disk/memory
whether ~/jerry-telemetry-agent exists

Do not deploy or modify LAX.

11. Docker/LAX docs

Update:

docs/LAX_BACKEND_USAGE_DOCKER_MIGRATION.md
docs/PROVIDERS.md
docs/CONFIGURATION.md
docs/TROUBLESHOOTING.md
docs/SECURITY.md
docs/GLANCE_DASHBOARD.md

Make clear:

backend usage is primary
tmux /status is fallback only
host only needs Docker + installed/authenticated Codex for backend usage Docker mode
Docker must mount Codex auth dir read-only
Docker image must not include auth.json
LAX production timer remains unchanged until manual approval
12. Gitignore

Ensure these are ignored:

.smoke/
codex-usage-test/
*.raw.local-only.json
*.safe.snapshot.json
.env
.env.*
*.local.env
auth.json

Avoid excessive duplicate entries.

13. Tests

Add/update tests for:

tokens.access_token auth schema
missing tokens.access_token
explicit CODEX_HOME
HTTP error mappings
normalizer default rate_limit
normalizer additional GPT-5.3-Codex-Spark limit
reset_at_iso conversion
sensitive field omission
error snapshot
last-good stale behavior
summary generation
file output path behavior
tmux fallback remains disabled by default
Required validation

Run:

npm install
npm run typecheck
npm test
npm run build
docker compose config
.\scripts\validate-local.ps1
.\scripts\scan-secrets-light.ps1
.\scripts\smoke-codex-backend-usage-local.ps1
Success criteria

The real local smoke should end with:

status_ok=True
limits_count > 0
default_limit_found=True when default limit is present
spark_limit_found=True when GPT-5.3-Codex-Spark is present

If it still fails due external auth/network issues, report:

error_code
safe message
safe diagnostics
next required manual check
Git / PR automation

You may automate Git and PR operations for this goal.

Workflow:

Ensure local main is clean and up to date.
Create a feature branch from main.
Implement the goal.
Run validation.
Commit changes.
Push the feature branch.
Create a GitHub PR to main.
Wait for CI checks.
If CI passes and no high-risk files are touched, squash-merge the PR and delete the branch.
Checkout main and pull latest.
Report final commit SHA, PR number, validation results, and remaining risks.

Do not auto-merge if:

CI fails.
Secret scan fails.
The diff includes .env, *.local.env, auth.json, access_token, refresh_token, or raw response dumps.
The change modifies production deployment, LAX/beijing runtime configuration, systemd timers, reverse proxy, database migrations, or live telemetry hub settings.
The change breaks codex.usage.snapshot v1.
The change requires manual production rollout.
