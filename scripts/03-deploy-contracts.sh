#!/usr/bin/env bash
# SynapsVault — Step 3: Build + Deploy all 3 Soroban contracts to Stellar testnet
#
# Prerequisites:
#   - Rust + wasm32 target:  rustup target add wasm32-unknown-unknown
#   - Stellar CLI:           https://developers.stellar.org/docs/tools/cli
#                            (the legacy `soroban` CLI is used as a fallback)
#   - A checkout of https://github.com/SynapsVault/contracts
#   - Funded DEPLOYER wallet (run scripts/02-fund-accounts.js first)
#
# Usage:
#   export DEPLOYER_SECRET=S...your_deployer_secret...
#   export CONTRACTS_DIR=../contracts   # optional; defaults to ../contracts
#   bash scripts/03-deploy-contracts.sh
#
# Output: contract-ids.env  (source this before running 04-init-contracts.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_FILE="$SCRIPT_DIR/../contract-ids.env"

CONTRACTS_DIR="${CONTRACTS_DIR:-$SCRIPT_DIR/../../contracts}"
if [[ ! -f "$CONTRACTS_DIR/Cargo.toml" ]]; then
  echo "❌  Contracts workspace not found at $CONTRACTS_DIR"
  echo "    Clone https://github.com/SynapsVault/contracts and set CONTRACTS_DIR."
  exit 1
fi
CONTRACTS_DIR="$(cd "$CONTRACTS_DIR" && pwd)"

if command -v stellar >/dev/null 2>&1; then
  CLI=stellar
elif command -v soroban >/dev/null 2>&1; then
  CLI=soroban
else
  echo "❌  Neither the stellar nor the soroban CLI is installed."
  exit 1
fi

if [[ -z "${DEPLOYER_SECRET:-}" ]]; then
  echo "❌  Set DEPLOYER_SECRET before running."
  exit 1
fi

# ── Configure Soroban CLI for testnet ────────────────────────────────────────
$CLI network add testnet \
  --rpc-url       https://soroban-testnet.stellar.org \
  --network-passphrase "Test SDF Network ; September 2015" 2>/dev/null || true

printf '%s\n' "$DEPLOYER_SECRET" | $CLI keys add deployer --secret-key 2>/dev/null || true

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
  # Progress goes to stderr; only `name=id` goes to stdout (and the env file).
  echo "" >&2
  echo "▸ Deploying $name…" >&2
  local id
  id=$($CLI contract deploy \
    --wasm     "$wasm" \
    --source   deployer \
    --network  testnet)
  echo "  Contract ID: $id" >&2
  echo "$name=$id"
}

# ── Deploy ────────────────────────────────────────────────────────────────────
{
  deploy_contract "vault_registry"
  deploy_contract "access_lease"
  deploy_contract "subscription"
} > "$OUT_FILE"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   All 3 contracts deployed to Stellar testnet ✅    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
cat "$OUT_FILE"
echo ""
echo "Contract IDs saved to: $OUT_FILE"
echo "Next → initialise contracts:"
echo "  source contract-ids.env"
echo "  bash scripts/04-init-contracts.sh"
echo ""
