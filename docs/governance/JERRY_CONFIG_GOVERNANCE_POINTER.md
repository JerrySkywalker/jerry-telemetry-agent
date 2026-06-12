# Jerry Config Governance Pointer

The authoritative Jerry config and secret governance document lives in:

```text
V:\src\jerry-telemetry-hub\docs\governance\jerry-config-and-secret-governance.md
```

Agent local overrides:

- LAX deploy mode is archive plus Docker build.
- LAX production is not a git worktree.
- LAX host must not run npm for production deploy.
- `HEALTH_PORT` is the container listener and defaults to `8081`.
- `HEALTH_HOST_PORT` is the host localhost binding and defaults to `18081`.
- Codex `auth.json` is read-only input from the host and must never be printed or backed up into the app repo.
