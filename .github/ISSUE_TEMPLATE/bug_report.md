---
name: Bug Report
about: Report a bug in deployment scripts, Kubernetes manifests, Dockerfiles, or CI workflows
title: "[bug] "
labels: ["bug"]
assignees: ""
---

## Affected Component

<!-- Check all that apply. -->

- [ ] `scripts/` — contract deploy/rollback, seed, smoke test, backup/restore/db-rollback
- [ ] `scripts/check-env.js` — environment variable validation
- [ ] `k8s/` — Kubernetes / Kustomize manifests
- [ ] `backend/Dockerfile` or `frontend/Dockerfile`
- [ ] `monitoring/` — Prometheus, Alertmanager, Grafana
- [ ] `.github/workflows/` — CI, K8s deploy, contract deploy, backups
- [ ] `docs/` — runbooks and guides
- [ ] `docker-compose.yml` / `.env.example`

## Environment

| Field | Value |
|-------|-------|
| OS / Shell | |
| Node.js version (`node --version`) | |
| npm version (`npm --version`) | |
| Target network | `testnet` / `mainnet` / `futurenet` / `local` |
| Deploy target | `compose` / `k8s` / `railway` |
| Relevant tool versions (kubectl, docker, etc.) | |

## Steps to Reproduce

1.
2.
3.

## Expected Behaviour

<!-- What should happen? -->

## Actual Behaviour / Error Output

```text
Paste relevant error output or logs here.
IMPORTANT: redact any secrets, keys, or connection strings before pasting.
```

## Additional Context

<!-- Links to related issues, relevant config snippets (redacted), or screenshots. -->
