# Deploy SynapsVault Contracts to Stellar Testnet

Run these steps **once locally** from your machine. Takes ~20 minutes total.

> **Preferred path:** use the automated scripts `scripts/deploy-contracts.cjs` and
> `scripts/rollback-contracts.cjs` (or the **Deploy Contracts** GitHub Actions
> workflow). The manual Stellar CLI steps below are kept as a fallback for
> debugging or when the scripts are unavailable.

---

## Automated deployment (preferred)

```bash
# 1. Build the WASM in your SynapsVault/contracts checkout
(cd ../contracts && cargo build --target wasm32-unknown-unknown --release --workspace)

# 2. Keep a copy of the current IDs so you can roll back later
cp contract-ids.env "contract-ids.env.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true

# 3. Deploy all contracts (uploads WASM, deploys, calls init(admin), verifies,
#    writes contract-ids.env). Add --dry-run to run only the pre-flight checks.
STELLAR_SECRET_KEY=S... \
ADMIN_PUBLIC_KEY=G...   `# optional; defaults to the deployer` \
CONTRACTS_WASM_DIR=../contracts/target/wasm32-unknown-unknown/release \
npm run deploy:contracts -- --network testnet

# Roll back: point the backend at a previous set of contract IDs
npm run rollback:contracts -- --backup contract-ids.env.<timestamp> \
  --network testnet --target-env .env [--configmap backend-config] [--dry-run]
```

The deploy script performs pre-flight checks (valid key, funded account, WASM
present), deploys `vault-registry`, `access-lease` and `subscription`,
initialises each with `init(admin)`, and writes the resulting contract IDs to
`contract-ids.env`. Mainnet requires typing a confirmation, or `--yes` in CI.

Soroban contracts are immutable, so rollback never removes anything on-chain:
it verifies that each contract in the backup file still exists on-chain, then
rewrites those IDs in the target `.env` file and (optionally) merge-patches the
Kubernetes ConfigMap. Restart the backend afterwards to pick up the change.

---

## Mainnet deployment safety checks

Before deploying to mainnet, the automated script runs a set of pre-flight checks
and requires explicit confirmation:

- **Network guard** — refuses to run against mainnet unless `--network mainnet`
  is passed explicitly; defaults to testnet.
- **Keypair validation** — verifies the deployer secret key is present, well-formed,
  and matches the expected public key.
- **Balance check** — confirms the deployer account holds enough XLM to cover
  upload and deployment fees.
- **WASM hash check** — builds the contracts and compares the resulting WASM hashes
  against the recorded hashes to detect unintended changes.
- **Contract ID check** — warns if any target contract ID already exists on-chain.
- **Confirmation prompt** — prints a summary of the network, deployer, contract IDs
  and WASM hashes, then requires you to type `yes` to proceed. Any other input aborts
  the deployment.

Only proceed once every check passes and you have reviewed the printed summary.

---

## Prerequisites (install once)

```bash
# 1. Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
rustup target add wasm32-unknown-unknown

# 2. Stellar CLI (the scripts fall back to the legacy `soroban` CLI)
#    See https://developers.stellar.org/docs/tools/cli

# 3. Verify
stellar --version
```

---

## Step 1 — Generate keypairs

```bash
cd deploy   # this repository; clone SynapsVault/contracts next to it
node scripts/01-generate-keypairs.js
```

Save all 5 keypairs in a password manager. You need:
- **DEPLOYER** secret key — for deploying contracts
- **BACKEND** public key — set as the admin of access-lease + subscription
- **PUBLISHER1/2** — for seeding the catalog
- **BUYER1** — for testing purchases

---

## Step 2 — Fund all accounts

```bash
node scripts/02-fund-accounts.js \
  GDEPLOYER... GBACKEND... GPUBLISHER1... GPUBLISHER2... GBUYER1...
```

Each account gets 10,000 XLM on testnet — free, takes ~5 seconds.

Check balances at: https://stellar.expert/explorer/testnet

---

## Step 3 — Build + deploy contracts (manual fallback)

> Prefer `npm run deploy:contracts` (see above). Use the manual steps below
> only if the automated script is unavailable.

```bash
export DEPLOYER_SECRET=Syour_deployer_secret_key_here
export CONTRACTS_DIR=../contracts   # your SynapsVault/contracts checkout

bash scripts/03-deploy-contracts.sh
```

This will:
1. Build all 3 contracts to WASM (`~3 minutes`)
2. Deploy `vault-registry` → prints contract ID
3. Deploy `access-lease` → prints contract ID
4. Deploy `subscription` → prints contract ID
5. Save all IDs to `contract-ids.env`

**Expected output:**
```
▸ Building WASM contracts…
✅ Build complete

▸ Deploying vault_registry…
  Contract ID: CCXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

▸ Deploying access_lease…
  Contract ID: CDXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

▸ Deploying subscription…
  Contract ID: CEXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

---

## Step 4 — Initialise contracts

```bash
source contract-ids.env

export DEPLOYER_SECRET=Syour_deployer_secret_key_here
export BACKEND_PUBLIC=Gyour_backend_wallet_public_key

bash scripts/04-init-contracts.sh
```

This calls `init(admin)` on `access-lease` and `subscription`, setting your backend
wallet as the sole lease-granting authority.

---

## Step 5 — Verify on Stellar Expert

Visit these URLs (replace with your actual contract IDs):

```
https://stellar.expert/explorer/testnet/contract/CC[vault_registry_id]
https://stellar.expert/explorer/testnet/contract/CD[access_lease_id]
https://stellar.expert/explorer/testnet/contract/CE[subscription_id]
```

You should see the contracts with their deployed WASM and storage entries.

---

## Step 6 — Add contract IDs to backend .env

```env
STELLAR_CONTRACT_VAULT_REGISTRY=CC...
STELLAR_CONTRACT_ACCESS_LEASE=CD...
STELLAR_CONTRACT_SUBSCRIPTION=CE...
```

Then redeploy the backend (Railway redeploys automatically on env change).

---

## Useful Soroban CLI commands

```bash
# Read vault-registry count
soroban contract invoke \
  --id $vault_registry --source deployer --network testnet \
  -- count

# Grant a test lease (30 days = 518400 ledgers)
soroban contract invoke \
  --id $access_lease --source deployer --network testnet \
  -- grant_lease \
  --resource_id "test-resource-1" \
  --buyer GBUYER1_PUBLIC_KEY \
  --duration_ledgers 518400

# Check if valid
soroban contract invoke \
  --id $access_lease --source deployer --network testnet \
  -- is_valid \
  --resource_id "test-resource-1" \
  --buyer GBUYER1_PUBLIC_KEY
# → true
```

---

## Troubleshooting

| Error | Fix |
|-------|-----|
| `account not found` | Fund the account with Friendbot first |
| `Error: wasm too large` | Run with `--release` flag |
| `insufficient balance` | Fund deployer wallet — needs XLM for fees |
| `contract already exists` | Use `--wasm-hash` flag to reuse existing upload |
| `Error: HostError: Value(InvalidInput)` | Check argument types match contract signature |
