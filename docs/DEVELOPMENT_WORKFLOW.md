# Development Workflow

`main` is the stable branch. Codex development work should happen on short-lived PR branches, for example:

- `feat/backend-usage-hardening`
- `fix/http-sink-spool`
- `docs/lax-deployment`

Create a branch with:

```powershell
scripts/new-pr-branch.ps1 feat/backend-usage-hardening
```

Before opening or updating a PR, run:

```powershell
scripts/pr-ready-check.ps1
```

The ready check requires a clean working tree, runs local validation, and prints a suggested `gh pr create` command. GitHub CLI is optional; the command is only a convenience.

## Pull Request Rules

- PRs target `main`.
- CI must pass before merge.
- Include validation commands in the PR description.
- Keep changes scoped to the goal or issue.
- Do not commit real secrets, `.env`, `.env.*`, `auth.json`, raw usage dumps, access tokens, refresh tokens, emails, account IDs, or user IDs.
- Do not deploy from PR branches.
- Do not add GitHub Actions secrets as part of normal development work.

## Local Validation

Run the same core checks locally:

```powershell
npm install
npm run typecheck
npm test
npm run build
docker compose config
scripts/validate-local.ps1
scripts/scan-secrets-light.ps1
```

`scripts/validate-local.ps1` uses `npm ci` when `package-lock.json` exists, then runs typecheck, tests, build, and Docker Compose configuration validation.

## Production Changes

Production LAX migration is manual and requires explicit approval. PR branches must not deploy to LAX, stop the current LAX systemd timer, or modify the production telemetry hub.
