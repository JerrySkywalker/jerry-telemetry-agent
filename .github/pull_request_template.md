## Summary

-

## Changed Areas

-

## Validation Commands

- [ ] `npm run typecheck`
- [ ] `npm test`
- [ ] `npm run build`
- [ ] `docker compose config`
- [ ] `scripts/validate-local.ps1`
- [ ] `scripts/scan-secrets-light.ps1`

## Security Checklist

- [ ] No raw Codex account IDs, session IDs, emails, access tokens, or refresh tokens are logged or uploaded.
- [ ] Telemetry secrets are not printed.
- [ ] Snapshot output remains normalized and redacted.

## Secrets Checklist

- [ ] No `.env`, `.env.*`, `auth.json`, local raw dumps, or real secrets are committed.
- [ ] GitHub Actions do not define production secrets for this change.

## Deployment Impact

-

## Rollback Notes

-
