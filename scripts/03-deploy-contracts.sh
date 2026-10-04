#!/usr/bin/env bash
# SynapsVault — Step 3: Build + Deploy all 3 Soroban contracts to Stellar testnet
#
# Prerequisites:
#   - Rust + wasm32 target:  rustup target add wasm32-unknown-unknown
#   - Soroban CLI:           cargo install --locked soroban-cli
#   - Funded DEPLOYER wallet (run scripts/02-fund-accounts.js first)
#
# Usage:
#   export DEPLOYER_SECRET=S...your_deployer_secret...
#   bash scripts/03-deploy-contracts.sh
#
# Output: contract-ids.env  (source this before running 04-init-contracts.sh)

set -euo pipefail

CONTRACTS_DIR="$(cd "$(dirname "$0")/../SynapsVault-contracts" && pwd)"
OUT_FILE="$(dirname "$0")/../contract-ids.env"

if [[ -z "${DEPLOYER_SECRET:-}" ]]; then
  echo "❌  Set DEPLOYER_SECRET before running."
  exit 1
fi

# ── Configure Soroban CLI for testnet ────────────────────────────────────────
soroban network add testnet \
  --rpc-url       https://soroban-testnet.stellar.org \
  --network-passphrase "Test SDF Network ; September 2015" 2>/dev/null || true

soroban keys add deployer --secret-key "$DEPLOYER_SECRET" 2>/dev/null || true

# ── Build all contracts ───────────────────────────────────────────────────────
echo ""
echo "▸ Building WASM contracts…"
cd "$CONTRACTS_DIR"
cargo build --target wasm32-unknown-unknown --release --workspace
echo "✅ Build complete"

WASM_DIR="$CONTRACTS_DIR/target/wasm32-unknown-unknown/release"

# ── Helper: deploy one contract ───────────────────────────────────────────────
deploy_contract() {
  local name="$1"
  local wasm="$WASM_DIR/${name}.wasm"
  echo ""
  echo "▸ Deploying $name…"
  local id
  id=$(soroban contract deploy \
    --wasm     "$wasm" \
    --source   deployer \
    --network  testnet)
  echo "  Contract ID: $id"
  echo "$name=$id"
}

# ── Deploy ────────────────────────────────────────────────────────────────────
echo "" > "$OUT_FILE"
deploy_contract "vault_registry"  | tee -a "$OUT_FILE"
deploy_contract "access_lease"    | tee -a "$OUT_FILE"
deploy_contract "subscription"    | tee -a "$OUT_FILE"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   All 3 contracts deployed to Stellar testnet ✅    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Contract IDs saved to: $OUT_FILE"
echo "Next → initialise contracts:"
echo "  source contract-ids.env"
echo "  bash scripts/04-init-contracts.sh"
echo ""
