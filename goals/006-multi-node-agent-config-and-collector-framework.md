/goal

Multi-node telemetry-agent config and typed collector framework.

Operator preference:

* Complete the goal autonomously.
* Diagnose failures, apply minimal fixes if needed, rerun validation, and keep the work reviewable.
* Do not ask the operator to run intermediate commands.
* Do not deploy.
* Do not SSH to LAX or any other node.
* Do not merge.
* Do not tag.

Repository:

* JerrySkywalker/jerry-telemetry-agent
* Local path:
  V:\src\jerry-telemetry-agent
* Base:
  main

Purpose:

* Make the agent portable beyond the LAX Codex usage node.
* Keep current LAX Codex behavior working.
* Introduce a typed collector registry and per-node declarative config shape.
* Support multiple node roles and different collector sets without arbitrary shell execution.
* Preserve safe redaction, HMAC upload, spool/retry, state, and agent health behavior.

Hard forbidden actions:

* Do not modify `jerry-telemetry-hub`.
* Do not modify Hermes.
* Do not modify dashboard.
* Do not deploy to LAX or any node.
* Do not stop, start, restart, enable, disable, or edit systemd services/timers.
* Do not run `docker compose up`.
* Do not print `.env`, `auth.json`, access tokens, refresh tokens, id tokens, account IDs, user IDs, emails, node secrets, Authorization headers, cookies, or raw backend responses.
* Do not add arbitrary command execution collectors.
* Do not make unknown collector names silently succeed.
* Do not break existing `codex-backend-usage` mode.
* Do not merge.
* Do not tag.

Review surfaces:

* src/config.ts
* src/main.ts
* src/telemetry/envelope.ts
* src/telemetry/sanitize.ts
* src/telemetry/uploader.ts
* src/telemetry/spool.ts
* src/health/agentHealth.ts
* src/collectors/codex/index.ts
* src/collectors/codex/normalizer.ts
* src/types/codex-usage.ts
* src/types/agent-health.ts
* docs/ARCHITECTURE.md
* docs/CONFIGURATION.md
* docs/PROVIDERS.md
* docs/SECURITY.md
* docs/LAX_BACKEND_USAGE_DOCKER_MIGRATION.md
* deploy/lax/docker-compose.yml.example
* deploy/lax/.env.example
* tests/*.test.ts

Tasks:

1. Verify repository state.

   Run:

   * git status --short --branch
   * git branch --show-current
   * git rev-parse HEAD
   * git log --oneline -10

2. Preserve current behavior.

   Confirm before edits:

   * default collector remains `codex-backend-usage`
   * `TELEMETRY_NODE_ID=us-lax-pro-01` remains documented for LAX
   * `TELEMETRY_OUTPUT_MODE=file,http` remains the production LAX target
   * daemon emits `codex.usage.snapshot`
   * daemon emits `telemetry.agent.health`
   * no raw backend response is uploaded

3. Design typed collector registry.

   Add a simple registry shape that supports known collectors only.

   Initial allowed collectors:

   * `codex-backend-usage`
   * `codex-cli-status-fallback`
   * `agent-health`

   Optional stub collectors may be documented but must not be enabled unless implemented and tested.

   Requirements:

   * unknown collector names fail closed
   * collector-specific config is typed
   * collectors return safe payloads only
   * collector event_type is explicit
   * collector intervals can be documented but do not need complex scheduling in this goal

4. Add per-node config shape.

   Support or document a declarative config shape such as:

   ```json
   {
     "node_id": "us-lax-pro-01",
     "hostname": "novix-lax-01",
     "region": "us-lax",
     "role": "codex-node",
     "collectors": [
       { "name": "codex-backend-usage", "enabled": true, "interval_seconds": 300 },
       { "name": "agent-health", "enabled": true, "interval_seconds": 300 }
     ]
   }
   ```

   If implementing file-based config is too much for this goal, document it and keep env compatibility. Do not remove existing env support.

5. Generalize envelope event type safely.

   Current envelope has a narrow event type union. Adjust only if needed so typed collectors can emit explicit event types.

   Requirements:

   * event type still validates against Hub-compatible pattern
   * Codex usage and agent health event types remain unchanged
   * no collector can emit arbitrary unsafe event types without registry validation

6. Keep LAX compatibility.

   Add tests or fixtures proving:

   * existing env-only LAX config still loads
   * default collector remains backend usage
   * `--collector codex-cli-status-fallback` still works
   * output modes still parse correctly
   * missing upload config still fails before HTTP upload

7. Update docs.

   Update docs to state:

   * agent is intended for many nodes
   * node identity is `TELEMETRY_NODE_ID`
   * each node has a unique secret
   * collectors are typed and allowlisted
   * arbitrary shell collectors are intentionally not supported
   * LAX Codex usage is one collector profile, not the whole product
   * secrets gate stops deployment/config rendering when required values are missing

8. Run validation.

   Required:

   * npm run typecheck
   * npm test
   * npm run build
   * docker compose config
   * .\scripts\validate-local.ps1
   * .\scripts\scan-secrets-light.ps1
   * git diff --check
   * git status --short --branch

   Do not run production upload scripts.

9. If a blocking issue is found.

   * Apply the smallest possible fix.
   * Rerun relevant checks.
   * Rerun full validation.
   * Do not deploy.
   * Do not merge.
   * Do not tag.

Final output required:

* Current branch and latest commit.
* Files changed.
* Collector registry result.
* Per-node config result.
* LAX compatibility result.
* Security/redaction result.
* Tests added or updated.
* Validation results.
* Safety boundary confirmation.
* Follow-up goals for actual non-LAX pilot nodes.
