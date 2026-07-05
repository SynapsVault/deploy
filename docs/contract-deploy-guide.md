# Deploy AtriumMind Contracts to Stellar Testnet

Run these steps **once locally** from your machine. Takes ~20 minutes total.

---

## Prerequisites (install once)

```bash
# 1. Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
rustup target add wasm32-unknown-unknown

# 2. Soroban CLI
cargo install --locked soroban-cli

# 3. Verify
soroban --version
# → soroban 21.x.x
```

---

## Step 1 — Generate keypairs

```bash
cd AtriumMind-contracts  # or wherever you cloned
node ../atriumind-deploy/scripts/01-generate-keypairs.js
```

Save all 5 keypairs in a password manager. You need:
- **DEPLOYER** secret key — for deploying contracts
- **BACKEND** public key — set as the admin of access-lease + subscription
- **PUBLISHER1/2** — for seeding the catalog
- **BUYER1** — for testing purchases

---

## Step 2 — Fund all accounts

```bash
node ../atriumind-deploy/scripts/02-fund-accounts.js \
  GDEPLOYER... GBACKEND... GPUBLISHER1... GPUBLISHER2... GBUYER1...
```

Each account gets 10,000 XLM on testnet — free, takes ~5 seconds.

Check balances at: https://stellar.expert/explorer/testnet

---

## Step 3 — Build + deploy contracts

```bash
export DEPLOYER_SECRET=Syour_deployer_secret_key_here

bash ../atriumind-deploy/scripts/03-deploy-contracts.sh
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

bash ../atriumind-deploy/scripts/04-init-contracts.sh
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
