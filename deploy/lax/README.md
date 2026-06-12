# LAX Deployment Directory

Target directory on LAX:

```text
~/jerry-telemetry-agent
```

Expected files and directories:

- `.env`, created on the host from [deploy/lax/.env.example](./.env.example) or by `scripts/lax-agent-dry-run.ps1`
- `deploy/lax/.env`, mirrored by the dry-run because Compose resolves `env_file: .env` relative to `deploy/lax/docker-compose.yml.example`
- `state/`, created on the host and mounted into the container as `/state`
- `deploy/lax/docker-compose.yml.example`, copied to or referenced as the Compose file
- `/home/ubuntu/.codex`, mounted read-only as `/host-codex-home`

The Codex auth mount must stay read-only:

```yaml
volumes:
  - /home/ubuntu/.codex:/host-codex-home:ro
  - ./state:/state
```

Dry-run uses `AGENT_MODE=once` and `TELEMETRY_OUTPUT_MODE=stdout,file`; it must not include `http` or `TELEMETRY_NODE_SECRET`.

Hotfix deployment should use `scripts/deploy-lax-agent-archive.ps1` after the fix is merged to `main`. The script creates a local `git archive` from `main`, copies it to LAX, backs up the current directory, preserves `.env`, `.env.*`, `logs/`, `state/`, `deploy/*/.env`, and `deploy/*/state/`, then builds through Docker Compose. It does not run npm on LAX.

Safe diagnostics should use `scripts/diag-lax-agent-safe.ps1`. It reports only existence, mtime, key presence, type, counts, and marker presence.
