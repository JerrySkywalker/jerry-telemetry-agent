# CD Plan

This repository currently uses CI only. Production deployment remains manual until later phases are explicitly approved.

## Phase 1: CI Only

- Run GitHub Actions on pull requests and pushes to `main`.
- Validate TypeScript, tests, build output, and Docker Compose configuration.
- Do not configure production secrets or deployment jobs.

## Phase 2: Manual Deploy Script

- Add a reviewed manual script for packaging and deploying the agent.
- Require operators to provide secrets out of band.
- Keep production hub changes out of this repository.
- Require explicit manual approval before touching the LAX node.

## Phase 3: Tag-Based Release

- Build release artifacts from signed or protected tags.
- Record changelog, validation evidence, and rollback notes.
- Deploy only from release tags, not PR branches.

## Phase 4: Protected GitHub Actions Deployment

- Add deployment jobs only after environment protection is configured.
- Store secrets in protected GitHub Environments, not workflow files.
- Require manual approvals for production.
- Keep rollback steps tested before enabling automated production rollout.
