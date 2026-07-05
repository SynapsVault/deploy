# AtriumMind — Deployment Runbook

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

---

## Prerequisites

Install these before starting:

```bash
# Rust + wasm target
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
rustup target add wasm32-unknown-unknown

# Soroban CLI
cargo install --locked soroban-cli
soroban --version   # should print 21.x.x

# Node.js 20+ (for scripts)
node --version   # should print v20.x.x

# Railway CLI (optional — can use dashboard instead)
npm install -g @railway/cli
```

---

## Steps

### Step 1 — Generate keypairs

```bash
cd AtriumMind-contracts   # or the deploy folder
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

bash scripts/03-deploy-contracts.sh    # builds + deploys, ~20 min
source contract-ids.env
bash scripts/04-init-contracts.sh      # calls init() on each contract
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
1. Show the live URL (https://atriumind.vercel.app)
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
- `https://atriumind-backend.up.railway.app` with your actual Railway URL
- `https://atriumind.vercel.app` with your actual Vercel URL
- Add the demo video URL in Section 12

Then submit the interest form at: https://communityfund.stellar.org/awards

---

## Troubleshooting

See [docs/contract-deploy-guide.md](./docs/contract-deploy-guide.md) for contract issues.
See [docs/railway-deploy.md](./docs/railway-deploy.md) for backend issues.

For SCF questions: Stellar Dev Discord → #scf-general
