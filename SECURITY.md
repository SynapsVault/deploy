# Security Policy

## Supported Versions

Only the latest state of the `main` branch and the active production deployment
manifests receive security updates.

| Branch / State       | Supported |
| -------------------- | --------- |
| `main` (HEAD)        | ✅        |
| Older commits / tags | ❌        |

---

## Scope

This policy covers security issues in:

| Component                                   | Examples                                                   |
| ------------------------------------------- | ---------------------------------------------------------- |
| `scripts/`                                  | Contract deploy/rollback, backup, seed, smoke-test scripts |
| `k8s/`                                      | Kubernetes manifests and Kustomize overlays                |
| `backend/Dockerfile`, `frontend/Dockerfile` | Image builds                                               |
| `.github/workflows/`                        | CI, deploy, backup workflows                               |
| `monitoring/`                               | Prometheus, Alertmanager, Grafana configuration            |
| `docs/`                                     | Runbooks that contain security-relevant instructions       |

Issues in the application code itself (`SynapsVault/backend`,
`SynapsVault/frontend`, `SynapsVault/contracts`) should be reported to those
repositories.

---

## Reporting a Vulnerability

**Please do not use public GitHub issues, discussions, or pull requests to
report security vulnerabilities.**

### Option 1 — GitHub Private Vulnerability Reporting (preferred)

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with the details below.

GitHub will notify the maintainers privately and open a draft security advisory.

### Option 2 — Email

Send a report to **security@synapsvault.xyz** with the subject line:

```
[SECURITY] <short description>
```

Include:

- **Affected component**: which directory or file (e.g., `scripts/backup.sh`,
  `k8s/secrets.yaml`, `.github/workflows/deploy-k8s.yml`).
- **Reproduction steps**: the minimal sequence of actions to trigger the issue.
- **Proof of concept** (if applicable): a script, manifest diff, or screenshot.
- **Potential impact**: what an attacker could do if they exploited this.
- **Suggested remediation** (optional): your recommended fix.

Redact any real secrets, keys, or connection strings before sending.

---

## Response SLA

| Milestone                              | Target                                                       |
| -------------------------------------- | ------------------------------------------------------------ |
| Initial acknowledgment                 | Within **48 hours**                                          |
| Triage and severity assessment         | Within **5 business days**                                   |
| Remediation and coordinated disclosure | Within **14–30 days** (depending on severity and complexity) |

We follow [coordinated vulnerability disclosure](https://cheatsheetseries.owasp.org/cheatsheets/Vulnerability_Disclosure_Cheat_Sheet.html).
If a fix requires more than 30 days we will communicate a revised timeline.

---

## Operational Security Guidelines

Follow these rules in all contributions to this repository.

### Secrets

- **Zero secrets in Git.** Never commit `.env`, `secrets.env`, `kubeconfig`,
  Stellar secret keys (`S...`), service-role JWT tokens, or unencrypted
  database dumps.
- `k8s/secrets.yaml` is a **placeholder template only** and must never be added
  to `k8s/kustomization.yaml` or pushed with real values.
- Use `node scripts/check-env.js` before deploying to catch placeholder values
  (e.g. `REPLACE_ME_*`, `change-me-*`, `S[X...]`, `C[X...]`) that were never
  replaced.
- The CI `secrets` job runs [gitleaks](https://github.com/gitleaks/gitleaks)
  on every push and pull request. A gitleaks finding blocks merging.

### Backups

- Production backups (`scripts/backup.sh`) **must** use `gpg` or `age`
  encryption. `BACKUP_ENCRYPTION_METHOD=none` is forbidden in production.
- Backup archives are uploaded to S3 with server-side encryption. Never store
  unencrypted dumps in a public bucket.

### Mainnet guardrails

- Contract deployments (`scripts/deploy-contracts.cjs`) and database restores
  (`scripts/restore.sh`) require explicit operator confirmation (interactive
  prompt or `--yes` flag) before modifying live state.
- The `STELLAR_NETWORK` environment variable must be set to `mainnet` explicitly
  — scripts default to `testnet`.

### Supply chain

- Dependencies are pinned to exact versions in `package.json` and
  `package-lock.json`. Open-ended ranges (`^`, `~`) require maintainer approval.
- Dependabot is configured to open weekly PRs for dependency updates
  (`.github/dependabot.yml`).
- Container images built in CI are scanned with Trivy; any unfixed CRITICAL CVE
  fails the build.
- Images pushed to production are signed with cosign (keyless, Sigstore).

### Workflow permissions

- All GitHub Actions workflows use the minimum required `permissions` scope.
  `contents: read` is the default; write access is granted only where
  explicitly needed (e.g., pushing images, uploading SARIF).
- Secrets are never echoed in workflow logs (`set -x` is prohibited in `run:`
  blocks that handle secrets).

---

## Security-relevant changes

Changes to the following areas require a review comment explaining the security
implications:

- `k8s/secrets.yaml` or any file that touches how secrets are injected
- `.github/workflows/` — any change to how secrets are consumed or exported
- `scripts/backup.sh` or `scripts/restore.sh`
- `scripts/deploy-contracts.cjs` (mainnet guard logic)
- Dockerfile `USER`, `RUN`, or `COPY` instructions that affect the runtime
  attack surface

Tag such PRs with the `security` label so they receive a dedicated review.
