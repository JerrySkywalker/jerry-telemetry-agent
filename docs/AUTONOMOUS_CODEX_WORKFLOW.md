# Autonomous Codex Workflow

This repository allows Codex to complete routine development goals through a full
feature-branch and pull-request lifecycle when the goal grants autonomous Git/PR
permission.

## Normal Autonomous Goal Flow

Use a short-lived branch from `main`:

```powershell
.\scripts\run-goal-pr.ps1 `
  -BranchName feat/example-goal `
  -CommitMessage "Implement example goal" `
  -PrTitle "Implement example goal" `
  -PrBody "Summary and validation notes." `
  -AutoMergeSafe
```

The script verifies the repository, starts from clean `main`, fetches and pulls
with `--ff-only`, creates the feature branch, runs validation, commits, pushes,
opens a PR with GitHub CLI, and can call `merge-pr-if-green.ps1` when safe.

If the script creates the branch and finds no changes, it exits with
`status=no_changes`. Implement the goal on that branch, then rerun the command.

## Risky Goal Flow

Use the same branch and validation flow, but omit `-AutoMergeSafe`:

```powershell
.\scripts\run-goal-pr.ps1 `
  -BranchName fix/risky-change `
  -CommitMessage "Fix risky change" `
  -PrTitle "Fix risky change" `
  -PrBody "Requires manual review before merge."
```

Risky PRs should remain open for manual inspection even if CI passes.

## Auto-Merge Rules

Auto-merge is allowed only when all of these are true:

- The user explicitly allowed autonomous PR handling for the goal.
- Local validation passed.
- GitHub CI checks passed.
- The PR does not change high-risk files.
- The diff does not include obvious secret markers.
- The PR does not deploy LAX or modify the production telemetry hub.

`merge-pr-if-green.ps1` refuses auto-merge for high-risk paths such as `.env`,
`*.local.env`, `auth.json`, `systemd/*`, `docker-compose.prod.yml`, database
migrations, reverse proxy configs, and live production deployment docs.

## Manual Approval Required

Manual approval is required before:

- Deploying to LAX.
- Stopping or modifying the current LAX systemd timer.
- Modifying the production telemetry hub.
- Adding or changing production secrets.
- Merging PRs that touch high-risk files.
- Merging PRs whose checks fail or are inconclusive.

## Dry-Run Examples

Preview the goal PR flow:

```powershell
.\scripts\run-goal-pr.ps1 `
  -BranchName feat/example-goal `
  -CommitMessage "Implement example goal" `
  -PrTitle "Implement example goal" `
  -PrBody "Dry-run only." `
  -DryRun
```

Preview a guarded merge:

```powershell
.\scripts\merge-pr-if-green.ps1 -PrNumber 123 -DeleteBranch -Squash -DryRun
```

## Recovery

Interrupted merge:

```powershell
gh pr view <number> --json state,merged,url
gh pr checks <number>
git switch main
git pull --ff-only origin main
```

If the PR is still open and checks are green, rerun:

```powershell
.\scripts\merge-pr-if-green.ps1 -PrNumber <number> -DeleteBranch -Squash
```

Dirty local `main`:

```powershell
git status --short
```

Move unrelated work to a feature branch or stash it before starting autonomous
work. Do not discard changes unless the owner explicitly approves it.

Inspect PR checks:

```powershell
gh pr checks <number>
gh pr checks <number> --watch --fail-fast
```
