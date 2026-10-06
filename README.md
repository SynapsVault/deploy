# SynapsVault — Deployment Runbook

Complete step-by-step guide to go from zero to a live testnet deployment
ready for SCF Build Award submission.

**Total time: ~3 hours** (mostly waiting for builds/deploys)

---

## Overview

```
Step 1  Generate keypairs          (5 min)
Step 2  Fund testnet accounts      (5 min)
Step 3  Build + deploy contracts   (20 min — mostly build time)
Step 4  Initialise contracts       (5 min)
Step 5  Deploy backend to Railway  (20 min)
Step 6  Run migrations             (5 min)
Step 7  Deploy frontend to Vercel  (10 min — already linked to GitHub)
Step 8  Seed the catalog           (10 min)
Step 9  Smoke test                 (5 min)
Step 10 Record demo video          (30 min)
```

For local development, production Kubernetes deployment, database rollback,
and automated contract deployment, see the dedicated sections below.

### Repository layout

This repo holds deployment tooling only; the application code lives in
[SynapsVault/backend](https://github.com/SynapsVault/backend),
[SynapsVault/frontend](https://github.com/SynapsVault/frontend) and
[SynapsVault/contracts](https://github.com/SynapsVault/contracts).

| Path | Contents |
|------|----------|
| `backend/Dockerfile`, `frontend/Dockerfile` | Image builds (the build context is a checkout of the app repo) |
| `k8s/` | Kustomize manifests for production |
| `scripts/` | Contract deploy/rollback, catalog seeding, smoke test, DB backup/restore/rollback |
| `monitoring/` | Prometheus, Alertmanager and Grafana config |
| `.github/workflows/` | CI, image build + K8s deploy, contract deploy, scheduled backups |
| `test/` | Unit tests for the contract scripts (`npm test`) |

---

## Local Development (Docker Compose)

Clone the application repos next to this one, then bring up the full stack
from this repo's root (compose builds the images from the sibling checkouts):

```bash
git clone https://github.com/SynapsVault/backend  ../backend
git clone https://github.com/SynapsVault/frontend ../frontend
cp .env.example .env
docker compose up --build
```

Service URLs (ports are configurable in `.env`):

| Service    | URL                     |
|------------|-------------------------|
| Frontend   | http://localhost:8080   |
| Backend    | http://localhost:3000   |
| Postgres   | localhost:5432          |
| Prometheus | http://localhost:9090   |
| Grafana    | http://localhost:3001   |

Database migrations run automatically: the one-shot `migrate` service applies
them before `backend` starts. To re-run them manually:

```bash
docker compose run --rm migrate
```

---

## Production Deployment (Kubernetes)

Production deployments run on Kubernetes. Manifests live in [`k8s/`](./k8s/)
and the full runbook is in
[docs/DEPLOY-KUBERNETES.md](./docs/DEPLOY-KUBERNETES.md).

---

## Database Rollback

If a migration needs to be reverted, follow
[docs/DATABASE-ROLLBACK.md](./docs/DATABASE-ROLLBACK.md).

---

## Automated Contract Deployment

Contracts are deployed via
[`scripts/deploy-contracts.cjs`](./scripts/deploy-contracts.cjs)
(`npm run deploy:contracts`) and the **Deploy Contracts** GitHub Actions
workflow (manual dispatch), which builds `SynapsVault/contracts` and deploys to
testnet or — after environment approval — mainnet. It needs the
`DEPLOYER_SECRET_KEY` secret (plus `MAINNET_RPC_URL` for mainnet). Roll back to
previous contract IDs with
[`scripts/rollback-contracts.cjs`](./scripts/rollback-contracts.cjs). See
[docs/contract-deploy-guide.md](./docs/contract-deploy-guide.md).

---

## Continuous Integration

The **CI** workflow runs on every pull request and push to `main`:

| Job | Checks |
|-----|--------|
| Lint GitHub workflows | `actionlint` (including shellcheck of `run:` blocks) |
| Lint shell scripts | `shellcheck` + `bash -n` on `scripts/*.sh` |
| Node scripts and tests | syntax check, `npm test`, CLI smoke tests |
| Validate Kubernetes manifests | `kubectl kustomize` + `kubeconform -strict` |
| Validate monitoring config | `promtool`, `amtool`, dashboard JSON |
| Validate docker-compose | `docker compose config` with `.env.example` |
| Build images | backend, backend-migrate and frontend images from the app repos |

Run the same checks locally before pushing:

```bash
npm ci && npm test
shellcheck scripts/*.sh
kubectl kustomize k8s/ > /dev/null
cp .env.example .env && docker compose config --quiet
```

---

## Prerequisites

Install these before starting:

```bash
# Rust + wasm target
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
rustup target add wasm32-unknown-unknown

# Stellar CLI (successor to soroban-cli; scripts fall back to `soroban`)
# See https://developers.stellar.org/docs/tools/cli for install options
stellar --version

# Node.js 22.12+ (for scripts; required by @stellar/stellar-sdk 17)
nvm use             # reads .nvmrc
node --version      # should print v22.x.x or newer
npm ci

# Railway CLI (optional — can use dashboard instead)
npm install -g @railway/cli
```

---

## Steps

### Step 1 — Generate keypairs

```bash
cd deploy   # this repository
node scripts/01-generate-keypairs.js
```

Copy all 5 keypairs into a password manager **right now**.

### Step 2 — Fund testnet accounts

```bash
node scripts/02-fund-accounts.js \
  G[DEPLOYER]  G[BACKEND]  G[PUBLISHER1]  G[PUBLISHER2]  G[BUYER1]
```

Verify at: https://stellar.expert/explorer/testnet/account/G[DEPLOYER]

### Step 3–4 — Deploy + init contracts

```bash
export DEPLOYER_SECRET=S[your_deployer_secret]
export BACKEND_PUBLIC=G[your_backend_public_key]
export CONTRACTS_DIR=../contracts      # checkout of SynapsVault/contracts

bash scripts/03-deploy-contracts.sh    # builds + deploys, ~20 min
source contract-ids.env
bash scripts/04-init-contracts.sh      # calls init() on each contract
```

Or do both steps in one go with the SDK-based deployer (no Stellar CLI
needed; build the WASM first):

```bash
STELLAR_SECRET_KEY=S[your_deployer_secret] ADMIN_PUBLIC_KEY=G[your_backend_public_key] \
CONTRACTS_WASM_DIR=../contracts/target/wasm32-unknown-unknown/release \
npm run deploy:contracts -- --network testnet
```

Save the contract IDs from `contract-ids.env` — you need them for the backend.

### Step 5 — Deploy backend to Railway

Follow: [docs/railway-deploy.md](./docs/railway-deploy.md)

Key env vars to set in Railway:
```
DATABASE_URL         = your Supabase connection string
STELLAR_CONTRACT_VAULT_REGISTRY  = from contract-ids.env
STELLAR_CONTRACT_ACCESS_LEASE    = from contract-ids.env
STELLAR_CONTRACT_SUBSCRIPTION    = from contract-ids.env
STELLAR_SECRET_KEY   = your BACKEND secret key
ADMIN_API_KEY        = openssl rand -hex 32
```

### Step 6 — Run migrations

In Railway shell:
```bash
pnpm drizzle-kit migrate
```

### Step 7 — Frontend already on Vercel

Your frontend is already connected to GitHub. Just update the env vars:
```
VITE_API_URL = https://[your-railway-app].up.railway.app
```
Then trigger a redeploy in Vercel.

### Step 8 — Seed the catalog

```bash
BACKEND_URL=https://[your-railway-app].up.railway.app \
node scripts/05-seed-catalog.js
```

This publishes 3 real resources to the catalog.

### Step 9 — Smoke test

```bash
BACKEND_URL=https://[your-railway-app].up.railway.app \
ADMIN_API_KEY=[your_admin_key] \
node scripts/06-smoke-test.js
```

All 6 checks should pass. Fix any failures before submitting.

### Step 10 — Record demo video

SCF requires a 3–5 minute demo video. Record:
1. Show the live URL (https://synapsvault.vercel.app)
2. Connect Freighter wallet
3. Browse the catalog — show 3 real resources
4. Click "Buy" on one resource — approve the USDC payment
5. Show the content delivered
6. Open Stellar Expert — show the contract interactions on-chain
7. Show admin panel (`/admin/stats`) — proves backend is live
8. Show GitHub repos — all 3, with recent commits and green CI

Upload to YouTube (unlisted) and paste the URL in the SCF submission form.

---

## After deployment — update the SCF submission

In `docs/SCF-submission.md`, replace these placeholders:
- `C[CONTRACT_ID]` with your actual contract IDs from `contract-ids.env`
- `https://synapsvault-backend.up.railway.app` with your actual Railway URL
- `https://synapsvault.vercel.app` with your actual Vercel URL
- Add the demo video URL in Section 12

Then submit the interest form at: https://communityfund.stellar.org/awards

---

## Monitoring & Alerting

See [docs/MONITORING.md](./docs/MONITORING.md) for the monitoring and alerting
runbook — health checks, dashboards, alert thresholds, and on-call procedures.

## Environment Variables

See [docs/ENVIRONMENT-VARIABLES.md](./docs/ENVIRONMENT-VARIABLES.md) for the
full reference of backend, frontend, and contract environment variables.

## Backup & Restore

See [docs/BACKUP-RESTORE.md](./docs/BACKUP-RESTORE.md) for the backup and
restore runbook — database snapshots, contract state recovery, and disaster
recovery procedures.

---

## Troubleshooting

See [docs/contract-deploy-guide.md](./docs/contract-deploy-guide.md) for contract issues.
See [docs/railway-deploy.md](./docs/railway-deploy.md) for backend issues.
See [docs/DEPLOY-KUBERNETES.md](./docs/DEPLOY-KUBERNETES.md) for Kubernetes deployment issues.
See [docs/DATABASE-ROLLBACK.md](./docs/DATABASE-ROLLBACK.md) for database rollback procedures.

For SCF questions: Stellar Dev Discord → #scf-general
