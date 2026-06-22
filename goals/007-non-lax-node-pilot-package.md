/goal

Non-LAX node pilot package for jerry-telemetry-agent.

Operator preference:

* Complete the goal autonomously.
* Diagnose failures, apply minimal fixes if needed, rerun validation, and keep the work reviewable.
* This goal prepares a pilot package only.
* Do not deploy to any node.
* Do not ask the operator to run intermediate commands.
* Do not merge.
* Do not tag.

Repository:

* JerrySkywalker/jerry-telemetry-agent
* Local path:
  V:\src\jerry-telemetry-agent
* Base:
  main
* Depends on:
  goals/006-multi-node-agent-config-and-collector-framework.md

Purpose:

* Prepare a safe pilot package for a non-LAX node.
* Prove the agent can be configured for a node that does not collect Codex usage.
* Keep the first non-LAX profile limited to safe agent health and optional host/system summary if implemented.
* Produce docs, examples, and local validation only.

Hard forbidden actions:

* Do not deploy to any node.
* Do not SSH to any node.
* Do not modify production Hub.
* Do not modify Hermes.
* Do not modify dashboard.
* Do not run production upload.
* Do not print or create real node secrets.
* Do not print `.env`, auth files, tokens, Authorization headers, cookies, or raw logs.
* Do not enable arbitrary command collectors.
* Do not assume Docker is installed on a target node unless checked in a future read-only preflight goal.
* Do not merge.
* Do not tag.

Review surfaces:

* deploy/
* docs/CONFIGURATION.md
* docs/PROVIDERS.md
* docs/OPERATIONS.md
* docs/SECURITY.md
* docs/ARCHITECTURE.md
* scripts/validate-local.ps1
* scripts/scan-secrets-light.ps1
* tests/*.test.ts
* src/config.ts
* src/main.ts
* src/health/agentHealth.ts
* src/telemetry/envelope.ts

Tasks:

1. Verify repository state.

   Run:

   * git status --short --branch
   * git branch --show-current
   * git rev-parse HEAD
   * git log --oneline -10

2. Choose a placeholder pilot profile.

   Use a non-secret placeholder such as:

   * node_id: `example-node-01`
   * hostname: `example-node-01`
   * region: `example-region`
   * role: `general-node`

   Do not invent real production node secrets.

3. Prepare example config.

   Add an example under `deploy/examples/` or equivalent.

   Required:

   * no real secrets
   * explicit `TELEMETRY_NODE_ID`
   * placeholder `TELEMETRY_NODE_SECRET`
   * `TELEMETRY_HUB_URL=https://telemetry.jerryskywalker.space/v1/events`
   * collector list does not include Codex unless explicitly selected
   * output defaults to `file` or safe local mode for examples
   * HTTP upload requires a manually supplied node secret

4. Add a local pilot smoke.

   Add or document a smoke that:

   * loads the example config
   * runs once without production upload
   * emits safe `telemetry.agent.health`
   * verifies event envelope node_id and event_type
   * verifies no forbidden markers
   * prints only safe booleans/counts/status

5. Define target-node preflight for future goal.

   Create docs for a future read-only preflight:

   * Docker availability
   * Docker Compose availability
   * disk/free memory
   * ability to reach `https://telemetry.jerryskywalker.space/healthz`
   * local state directory permissions
   * no existing conflicting service
   * no secrets printed

   Do not run this preflight against real nodes in this goal.

6. Preserve LAX behavior.

   Confirm docs and tests do not change:

   * LAX node_id
   * LAX Codex backend usage collector
   * LAX auth mount
   * old timer manual fallback status
   * production upload scripts

7. Run validation.

   Required:

   * npm run typecheck
   * npm test
   * npm run build
   * docker compose config
   * .\scripts\validate-local.ps1
   * .\scripts\scan-secrets-light.ps1
   * git diff --check
   * git status --short --branch

   Do not run LAX production scripts.

8. If a blocking issue is found.

   * Apply the smallest possible fix.
   * Rerun relevant checks.
   * Rerun full validation.
   * Do not deploy.
   * Do not merge.
   * Do not tag.

Final output required:

* Current branch and latest commit.
* Files changed.
* Pilot profile result.
* Example config result.
* Local pilot smoke result.
* Future target-node preflight result.
* LAX compatibility result.
* Validation results.
* Secret hygiene result.
* Safety boundary confirmation.
* Recommended first real non-LAX pilot goal.
