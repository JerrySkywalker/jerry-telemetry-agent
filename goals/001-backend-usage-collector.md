# Goal 001: Migrate Codex collection to backend usage snapshot

We are in YOLO development mode.

Read the current repository before changing code. Do not blindly rewrite the whole project.

## Product direction

`jerry-telemetry-agent` is a long-running local/node-side telemetry agent.

The previous Codex collection direction was based on:

- tmux
- Codex CLI `/status`
- capture-pane
- text parsing

This is now a fallback only.

The new primary collector is:

- read local Codex auth.json
- extract ChatGPT-managed access_token
- request ChatGPT backend usage endpoint
- normalize the response into a safe `codex.usage.snapshot`
- output through stdout/file/http sinks
- expose dashboard-friendly summary JSON

## Verified endpoint

Use this as the default:

https://chatgpt.com/backend-api/wham/usage

Do not use this as the main endpoint:

https://chatgpt.com/backend-api/codex/usage

It currently returns 403.

## Hard security constraints

Never print, upload, commit, persist in logs, or include in telemetry:

- access_token
- refresh_token
- auth.json raw content
- email
- account_id
- user_id
- referral_beacon
- promo
- full raw ChatGPT backend response

Do not implement OAuth refresh.
Do not call refresh endpoints.
Codex CLI is responsible for maintaining auth.

## P0: Schema

Create:

- src/types/codex-usage.ts
- docs/codex-usage-snapshot-v1.md

Define:

- CodexUsageSnapshot
- CodexRateLimit
- CodexRateWindow
- safe omitted raw keys
- compact dashboard summary type

Normalized schema should follow:

```ts
type CodexUsageSnapshot = {
  type: "codex.usage.snapshot";
  schema_version: 1;
  source: "chatgpt_backend_wham_usage";
  observed_at: string;
  collector: {
    name: "codex_backend_usage";
    version: string;
    endpoint_family: "wham_usage";
  };
  node: {
    id: string;
    hostname?: string;
    role?: string;
    platform?: string;
  };
  account: {
    label?: string;
    plan_type?: string;
  };
  status: {
    ok: boolean;
    allowed?: boolean;
    limit_reached?: boolean;
    rate_limit_reached_type?: string | null;
    error_code?: string;
    message?: string;
    stale?: boolean;
  };
  limits: CodexRateLimit[];
  credits?: {
    has_credits?: boolean;
    unlimited?: boolean;
    overage_limit_reached?: boolean;
    balance?: string;
    approx_local_messages?: [number, number] | number[];
    approx_cloud_messages?: [number, number] | number[];
  };
  spend_control?: {
    reached?: boolean;
    individual_limit?: unknown | null;
  };
  raw_omitted_keys: string[];
};
P1: Codex backend usage collector

Create or refactor modules:

src/collectors/codex/auth-provider.ts
src/collectors/codex/usage-client.ts
src/collectors/codex/normalizer.ts
src/collectors/codex/index.ts

Requirements:

Locate auth.json from:
CODEX_HOME
default ~/.codex
Read auth.json.
Extract access_token.
Never print token.
GET CODEX_USAGE_ENDPOINT.
Default endpoint:
https://chatgpt.com/backend-api/wham/usage
Set timeout.
Set reasonable User-Agent.
Return raw usage response only internally to normalizer.

Error codes:

auth_json_missing
access_token_missing
http_401
http_403
http_404
http_429
http_5xx
network_error
schema_error
P2: Normalizer

Map raw usage response to CodexUsageSnapshot.

Mapping rules:

raw.rate_limit -> limits[0]
scope = "default"
name = "default"
raw.additional_rate_limits[] -> additional limits
scope = "additional"
name = limit_name
metered_feature = metered_feature
limit_window_seconds -> window_seconds
reset_at -> reset_at_epoch and reset_at_iso
used_percent -> used_percent
remaining_percent = 100 - used_percent
raw.credits -> credits
raw.spend_control -> spend_control
raw.plan_type -> account.plan_type
raw.rate_limit_reached_type -> status.rate_limit_reached_type

Do not include raw email/account_id/user_id/referral_beacon/promo.

P3: Sinks

Implement sinks:

stdout
file
http telemetry hub

Environment/config:

TELEMETRY_OUTPUT_MODE=stdout,file,http
TELEMETRY_OUTPUT_FILE
TELEMETRY_HUB_URL
TELEMETRY_NODE_SECRET or compatible existing hub secret
TELEMETRY_ENABLE_RAW_DUMP=false

File sink:

write normalized event only
write latest snapshot
optionally write history
default no raw response

HTTP sink:

wrap normalized snapshot into hub event envelope:
event_type = codex.usage.snapshot
payload = normalized snapshot
sign using the existing HMAC rules if configured
do not send raw response
keep spool/retry behavior if current architecture has it
P4: Error snapshot and last-good

On success:

save last-good snapshot

On failure:

output a valid CodexUsageSnapshot with:
status.ok = false
status.error_code
status.message
status.stale = true if last-good exists
limits = []
never dump tokens or headers
preserve last-good file for dashboard consumers
P5: Runtime modes

Support:

--once
--daemon
--dry-run
--status
--collector codex-backend-usage
--collector codex-cli-status-fallback

Default collector mode:

codex-backend-usage

Polling:

CODEX_USAGE_POLL_INTERVAL_SECONDS
default 300 seconds
P6: Dashboard / Glance endpoint

If the agent already has a health server, extend it.

Add:

GET /api/codex/usage/latest
GET /api/codex/usage/summary

The summary should be compact and redacted.

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
last_success_at or received_at if available

Do not require Glance to parse raw response.

P7: tmux /status fallback

Keep legacy tmux /status logic only as fallback.

Rules:

default disabled
enabled only by TELEMETRY_ENABLE_TMUX_FALLBACK=true or explicit collector mode
fallback must output the same CodexUsageSnapshot shape
fallback source may be codex_cli_status_capture
do not remove old files unless they are clearly obsolete and tests/docs are updated
Configuration

Support:

CODEX_HOME
CODEX_USAGE_ENDPOINT
CODEX_USAGE_POLL_INTERVAL_SECONDS
TELEMETRY_NODE_ID
TELEMETRY_NODE_ROLE
TELEMETRY_ACCOUNT_LABEL
TELEMETRY_OUTPUT_MODE
TELEMETRY_OUTPUT_FILE
TELEMETRY_HUB_URL
TELEMETRY_NODE_SECRET
TELEMETRY_ENABLE_RAW_DUMP=false
TELEMETRY_ENABLE_TMUX_FALLBACK=false
Gitignore

Ensure secrets and raw local files are ignored:

*.raw.local-only.json
*.safe.snapshot.json
codex-usage-test/
.env
.env.*
*.local.env
auth.json

Do not over-duplicate if similar entries already exist.

Tests

Add or update tests for:

auth path resolution
auth_json_missing
access_token_missing
normalizer default rate_limit
normalizer additional_rate_limits
reset_at_iso conversion
raw sensitive fields omitted
error snapshot
last-good stale handling
stdout sink
file sink
http sink envelope adapter
summary generation
tmux fallback remains disabled by default
Docs

Update or add:

README.md
docs/ARCHITECTURE.md
docs/CONFIGURATION.md
docs/PROVIDERS.md
docs/SECURITY.md
docs/TROUBLESHOOTING.md
docs/codex-usage-snapshot-v1.md
docs/GLANCE_DASHBOARD.md

Make clear:

the new primary collector is backend usage
tmux /status is fallback only
raw response must not be sent to hub
auth.json must be mounted/read locally only
no OAuth refresh is implemented
Validation commands

Run:

npm install
npm run typecheck
npm test
npm run build
docker compose config

If Docker Hub is unreachable, record and continue.

Do not deploy to LAX.
Do not modify the production hub.
Do not stop current LAX systemd timer.
Do not commit real secrets.
