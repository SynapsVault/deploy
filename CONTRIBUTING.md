# Contributing to SynapsVault Deploy

Thank you for contributing to `SynapsVault/deploy`! This repository contains
the deployment scripts, Dockerfiles, Kubernetes Kustomize manifests, monitoring
configurations, and operational runbooks for the SynapsVault platform.

---

## Table of Contents

1. [Prerequisites & Setup](#1-prerequisites--setup)
2. [Running Tests & Quality Checks](#2-running-tests--quality-checks)
3. [Repository Conventions](#3-repository-conventions)
4. [Submitting a Pull Request](#4-submitting-a-pull-request)
5. [Reporting Issues](#5-reporting-issues)
6. [Security Vulnerabilities](#6-security-vulnerabilities)

---

## 1. Prerequisites & Setup

### Required tools

| Tool       | Version           | Purpose                                                        |
| ---------- | ----------------- | -------------------------------------------------------------- |
| Node.js    | `>= 22.12.0`      | Run and test scripts (`@stellar/stellar-sdk` v17+ requirement) |
| npm        | bundled with Node | Dependency management                                          |
| Bash       | any               | Shell scripts in `scripts/*.sh`                                |
| ShellCheck | any               | Lint shell scripts                                             |

Install Node.js via nvm (version is read from `.nvmrc`):

```bash
nvm use
node --version   # should print v22.x.x or newer
npm ci
```

### Optional tools (needed only for full local validation)

| Tool                    | Purpose                                      |
| ----------------------- | -------------------------------------------- |
| Docker & Docker Compose | Validate and smoke-test `docker-compose.yml` |
| kubectl                 | Validate Kubernetes manifests (`k8s/`)       |
| kubeconform             | Schema-validate rendered manifests           |
| kube-linter             | Policy-lint rendered manifests               |
| promtool / amtool       | Validate `monitoring/` config                |

### Local stack setup

Clone the sibling application repos, then start the full stack from this repo's
root — Compose builds images from those checkouts:

```bash
git clone https://github.com/SynapsVault/backend  ../backend
git clone https://github.com/SynapsVault/frontend ../frontend
cp .env.example .env
# Optional: edit .env to set real secrets if you need live Stellar/Supabase
node scripts/check-env.js --target compose   # flag missing/placeholder values
docker compose up --build
```

Service URLs (configurable via `.env`):

| Service    | URL                   |
| ---------- | --------------------- |
| Frontend   | http://localhost:8080 |
| Backend    | http://localhost:3000 |
| Postgres   | localhost:5432        |
| Prometheus | http://localhost:9090 |
| Grafana    | http://localhost:3001 |

---

## 2. Running Tests & Quality Checks

All pull requests are verified by `.github/workflows/ci.yml`. Run the same
checks locally before opening a PR.

### Environment variable check

Before starting the stack or running integration tests, verify that no
placeholder values remain in your `.env`:

```bash
node scripts/check-env.js --target compose   # local compose stack
node scripts/check-env.js --target k8s       # Kubernetes deploy
```

### Unit tests

```bash
npm test
```

Runs the Node.js built-in test runner against `test/**/*.test.cjs`.

### Linting & formatting

```bash
# ESLint
npm run lint

# Prettier (check only)
npm run format:check

# Prettier (auto-fix)
npm run format
```

### Shell script linting

```bash
shellcheck scripts/*.sh
for f in scripts/*.sh; do bash -n "$f"; done
```

### Kubernetes validation

```bash
kubectl kustomize k8s/ > rendered.yaml
kubeconform -strict -summary rendered.yaml
kube-linter lint rendered.yaml
```

### Monitoring validation

```bash
promtool check rules monitoring/alert-rules.yml
promtool test rules monitoring/tests/*.yml
amtool check-config monitoring/alertmanager.yml
python3 -m json.tool monitoring/grafana-dashboard.json > /dev/null
```

### Full pre-push checklist

```bash
npm ci
npm test
npm run lint
npm run format:check
node scripts/check-env.js --target compose
shellcheck scripts/*.sh
kubectl kustomize k8s/ > /dev/null
cp .env.example .env && docker compose config --quiet
```

---

## 3. Repository Conventions

### Node.js scripts (`scripts/*.js`, `scripts/*.cjs`)

- **Module format**: The package uses ES Modules (`"type": "module"`). Step
  scripts (`01`–`06`) and utilities (`.js`) use ESM. The standalone contract
  CLI tools (`deploy-contracts.cjs`, `rollback-contracts.cjs`) use CommonJS
  (`.cjs`) so their helpers can be `require()`-d by `test/*.test.cjs`.
- **Exit codes**: Scripts **must** exit non-zero (`process.exit(1)`) whenever
  required environment variables are missing, validation fails, or an RPC step
  fails. Never swallow errors silently.
- **No hard-coded secrets or mainnet defaults**: Default to `testnet`; require
  explicit `--yes` before executing destructive or mainnet operations.
- **Offline unit tests**: Export CLI argument parsers, environment validators,
  and file helpers so they can be unit-tested in `test/` without live network
  calls.

### Shell scripts (`scripts/*.sh`)

- Start with `#!/usr/bin/env bash` and `set -Eeuo pipefail`.
- Quote all variable expansions: `"${VAR}"`.
- Keep scripts clean under `shellcheck`.
- Document supported flags, environment variables, and exit codes in the header
  comment block so `--help` stays accurate.

### Kubernetes manifests (`k8s/`)

- **No real secrets in version control.** `k8s/secrets.yaml` is a placeholder
  template and must **not** be added to `k8s/kustomization.yaml`.
- All workloads must run as non-root with `allowPrivilegeEscalation: false` and
  explicit resource requests/limits.
- Use Kustomize overlays (`k8s/overlays/staging`, `k8s/overlays/production`) to
  separate environment-specific values from the base.

### Documentation (`docs/`, `README.md`)

- Each doc must have a clear purpose and cross-link to related docs rather than
  duplicating content.
- Railway deployment is documented once in
  [`docs/railway-deploy.md`](./docs/railway-deploy.md); all other mentions
  link there.
- Update `docs/ENVIRONMENT-VARIABLES.md` whenever a variable is added or
  renamed — that is the single source of truth.

### Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(k8s): add HorizontalPodAutoscaler for backend
fix(scripts): handle missing DEPLOYER_SECRET gracefully
docs: update Railway guide with Supabase pooler URL
test(contract): cover rollback with unknown contract ID
chore(deps): update @stellar/stellar-sdk to 17.3.0
```

Reference resolved issues in the commit body: `Closes #42`.

---

## 4. Submitting a Pull Request

1. **Fork** the repository and create a branch from `main`:
   ```bash
   git checkout -b feat/your-feature-name
   ```
2. Make your changes, following the conventions above.
3. Run the full pre-push checklist (see §2).
4. Open a PR against `main`. Fill in the PR template — link the issue, describe
   what changed and how you tested it.
5. At least one member of `@SynapsVault/core` must approve before merging.
6. Merge by **squash-and-merge** so every commit on `main` corresponds to one
   PR and references one issue.

### PR scope

Keep PRs focused. A PR that touches `k8s/`, `scripts/`, and `docs/` for the
same feature is fine; a PR that mixes unrelated changes is not. If you are
fixing a bug you found while working on a feature, open a separate PR for the
fix.

---

## 5. Reporting Issues

Use the GitHub issue templates:

- **[Bug report](.github/ISSUE_TEMPLATE/bug_report.md)** — for failures in
  scripts, manifests, Dockerfiles, CI workflows, or runbooks.
- **[Feature / Enhancement](.github/ISSUE_TEMPLATE/feature_request.md)** — for
  improvements to deployment automation, observability, or documentation.

Redact any secrets, keys, or connection strings before pasting logs.

---

## 6. Security Vulnerabilities

**Do not report security vulnerabilities through public issues.**

See [SECURITY.md](./SECURITY.md) for the responsible disclosure process.
