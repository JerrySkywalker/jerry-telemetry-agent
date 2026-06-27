# Agent Release Gate

`scripts/release-gate-local.ps1` is the local release gate for this agent repository. It runs repository checks, existing smokes, deployment-readiness scripts, and local package validation without production mutation.

Included checks:

- `npm run typecheck`
- `npm test`
- `npm run build`
- `docker compose config`
- `scripts/scan-secrets-light.ps1`
- `git diff --check`
- `scripts/validate-local.ps1`
- local one-shot Fixture and LocalWindows FileOnly batches
- `scripts/smoke-local-agent.ps1`
- `scripts/server-agent-once.ps1` FileOnly
- `scripts/smoke-server-agent.ps1`
- `scripts/smoke-server-daemon.ps1`
- local Hub+Agent E2E once and daemon modes when the sibling Hub exists
- `scripts/doctor-agent-config.ps1`
- `scripts/package-agent-local.ps1`
- install, upgrade, and uninstall dry-run plan scripts

The gate writes only local `.smoke` outputs. It creates a local-only synthetic env file for strict doctor validation and does not print the value in that file.

Output expectations:

- PASS/FAIL/SKIP lines are safe to paste.
- Missing Hub repo is reported as a skip.
- Secret values, raw env files, raw request bodies, HMAC signatures, Authorization headers, cookies, and raw backend responses must not be printed.
- Any failed required check makes the script exit nonzero.
