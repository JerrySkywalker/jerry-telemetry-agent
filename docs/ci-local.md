# Local CI

## Commands

- `npm run ci:local`
- `npm run release:gate:local`

## `ci:local`

Runs fast local validation suitable for PR checks:

- `npm run typecheck`
- `npm test`
- `npm run build`

## `release:gate:local`

Runs the stricter local release gate through `scripts/release-gate-local.ps1`.

Coverage includes:

- `npm run ci:local`
- `docker compose config`
- `scripts/scan-secrets-light.ps1`
- `git diff --check`
- `scripts/validate-local.ps1`
- file-only agent and server smoke tests
- local Hub/Agent end-to-end smoke tests when the sibling Hub repo is present
- doctor, package, install, upgrade, and uninstall dry-run gates
- optional canary evidence checks when local evidence exists

## Explicitly Excluded

- Production deployment.
- SSH.
- GitHub workflow mutation.
- Runner installation.
- Hub, Agent, or Dashboard production mutation.
- Production upload or live canary mutation.

## Production Safety Boundary

The local release gate writes only local `.smoke` artifacts and uses file-only or dry-run modes for Agent behavior. It does not deploy, SSH, or upload to production.

## Self-Hosted Runner Target

`[self-hosted, windows, jerry-ci]`
