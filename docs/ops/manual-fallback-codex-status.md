# Manual Fallback Codex Status

Use the old tmux/status chain only as a manual fallback for historical comparison or emergency debugging when the backend usage collector is unavailable.

Before use:

- Keep the automatic timer stopped.
- Do not modify Codex `auth.json`.
- Do not send raw status to the hub.
- Redact output before inspection.
- Do not paste raw tmux pane or `latest.json` content into chat.

Why it is not primary:

- tmux pane parsing is brittle.
- text output changes are hard to version.
- it depends on an interactive Codex session.
- sanitization is weaker than structured backend snapshots.
- it is harder to monitor without leaking context.

The primary runtime remains LAX Docker `jerry-telemetry-agent` producing `codex.usage.snapshot` and `telemetry.agent.health`.
