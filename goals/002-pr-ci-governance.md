# Goal 002: Add PR-based CI workflow and development automation

We are in YOLO development mode, but future work must use PR-based governance.

## Current state

The project now has:
- TypeScript telemetry agent
- Backend Codex usage collector
- Normalized codex.usage.snapshot schema
- stdout/file/http sinks
- last-good/error snapshot handling
- Glance-friendly summary endpoint
- tmux /status fallback disabled by default

The production LAX systemd timer is still using the older capture/send chain. Do not modify LAX in this goal.

## Goal

Make future Codex development faster and safer by adding:
- consistent CI
- PR workflow
- local validation scripts
- release/deploy gates
- branch naming and commit guidance

## Tasks

### 1. GitHub Actions CI

Ensure `.github/workflows/ci.yml` runs on:
- pull_request
- push to main

CI jobs:
- npm ci
- npm run typecheck
- npm test
- npm run build
- docker compose config

Do not require docker compose build if Docker Hub network makes CI flaky.

### 2. Local validation script

Add:

- scripts/validate-local.ps1

It should run:
- npm install or npm ci as appropriate
- npm run typecheck
- npm test
- npm run build
- docker compose config

It should fail non-zero on errors.

### 3. PR helper scripts

Add:

- scripts/new-pr-branch.ps1
- scripts/pr-ready-check.ps1

`new-pr-branch.ps1`:
- creates a feature branch from main
- refuses to run with dirty working tree unless `-Force`
- branch name examples:
  - feat/backend-usage-hardening
  - fix/http-sink-spool
  - docs/lax-deployment

`pr-ready-check.ps1`:
- verifies git status
- runs validate-local
- prints suggested `gh pr create` command
- does not require GitHub CLI to be installed

### 4. PR template

Add:

- .github/pull_request_template.md

Include:
- summary
- changed areas
- validation commands
- security checklist
- secrets checklist
- deployment impact
- rollback notes

### 5. Issue templates

Add:
- .github/ISSUE_TEMPLATE/bug_report.yml
- .github/ISSUE_TEMPLATE/feature_request.yml
- .github/ISSUE_TEMPLATE/collector_goal.yml

The collector goal template should support future collector tasks:
- codex backend usage
- server metrics
- docker container state
- network latency
- domain/tls expiry
- proxy health

### 6. Governance docs

Add:

- docs/DEVELOPMENT_WORKFLOW.md
- docs/CD_PLAN.md

DEVELOPMENT_WORKFLOW.md should explain:
- main is stable
- Codex works on feature branches
- PR must pass CI
- do not commit real secrets
- do not deploy from PR branches
- production LAX migration requires explicit manual approval

CD_PLAN.md should describe staged CD:
- Phase 1: CI only
- Phase 2: manual deploy script
- Phase 3: tag-based release
- Phase 4: optional GitHub Actions deployment with environment protection

Do not add secrets to GitHub Actions.
Do not configure actual production deployment in this goal.

### 7. Security guardrails

Add or improve checks/documentation for:
- no auth.json
- no .env
- no raw usage dump
- no access_token
- no refresh_token
- no email/account_id/user_id in snapshots

If practical, add:
- scripts/scan-secrets-light.ps1

This is not a full secret scanner, but it should catch obvious mistakes.

### 8. Update docs

Update:
- README.md
- AGENTS.md
- docs/SECURITY.md
- docs/TROUBLESHOOTING.md

Make the PR workflow explicit.

## Required validation

Run:
- npm install
- npm run typecheck
- npm test
- npm run build
- docker compose config
- scripts/validate-local.ps1
- scripts/scan-secrets-light.ps1 if added

## Constraints

- Do not deploy to LAX.
- Do not stop current LAX systemd timer.
- Do not modify production telemetry hub.
- Do not commit real secrets.
- Do not add frontend.
- Do not add PostgreSQL/Redis/queue.
- Do not change the codex.usage.snapshot schema unless there is a clear bug.
