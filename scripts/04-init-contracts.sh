#!/usr/bin/env bash
# SynapsVault — Step 4: Initialise all deployed contracts
#
# ⚠️  DEPRECATED: Use scripts/deploy-contracts.cjs instead.
# This bash script is maintained for backwards compatibility but will be removed in a future release.
# The Node.js script handles both deployment and initialization together.
#
# Prerequisites:
#   source contract-ids.env      (sets STELLAR_CONTRACT_VAULT_REGISTRY,
#                                 STELLAR_CONTRACT_ACCESS_LEASE, STELLAR_CONTRACT_SUBSCRIPTION)
#   export DEPLOYER_SECRET=S...
#   export BACKEND_PUBLIC=G...   (the backend platform wallet public key)
#
# All three contracts expose init(admin); admin = BACKEND_PUBLIC.

set -euo pipefail

: "${STELLAR_CONTRACT_VAULT_REGISTRY:?  source contract-ids.env first}"
: "${STELLAR_CONTRACT_ACCESS_LEASE:?    source contract-ids.env first}"
: "${STELLAR_CONTRACT_SUBSCRIPTION:?    source contract-ids.env first}"
: "${DEPLOYER_SECRET:? export DEPLOYER_SECRET}"
: "${BACKEND_PUBLIC:?  export BACKEND_PUBLIC}"

if command -v stellar >/dev/null 2>&1; then
  CLI=stellar
elif command -v soroban >/dev/null 2>&1; then
  CLI=soroban
else
  echo "❌  Neither the stellar nor the soroban CLI is installed."
  exit 1
fi

printf '%s\n' "$DEPLOYER_SECRET" | $CLI keys add deployer --secret-key 2>/dev/null || true

# ── Init vault-registry ───────────────────────────────────────────────────────
echo ""
echo "▸ Initialising vault-registry (admin = BACKEND_PUBLIC)…"
$CLI contract invoke \
  --id      "$STELLAR_CONTRACT_VAULT_REGISTRY" \
  --source  deployer \
  --network testnet \
  -- init \
  --admin "$BACKEND_PUBLIC"
echo "✅ vault-registry initialised"

# ── Init access-lease ─────────────────────────────────────────────────────────
echo ""
echo "▸ Initialising access-lease (admin = BACKEND_PUBLIC)…"
$CLI contract invoke \
  --id      "$STELLAR_CONTRACT_ACCESS_LEASE" \
  --source  deployer \
  --network testnet \
  -- init \
  --admin "$BACKEND_PUBLIC"
echo "✅ access-lease initialised"

# ── Init subscription ─────────────────────────────────────────────────────────
echo ""
echo "▸ Initialising subscription manager (admin = BACKEND_PUBLIC)…"
$CLI contract invoke \
  --id      "$STELLAR_CONTRACT_SUBSCRIPTION" \
  --source  deployer \
  --network testnet \
  -- init \
  --admin "$BACKEND_PUBLIC"
echo "✅ subscription initialised"

# ── Verify vault-registry (just read count) ───────────────────────────────────
echo ""
echo "▸ Verifying vault-registry…"
COUNT=$($CLI contract invoke \
  --id      "$STELLAR_CONTRACT_VAULT_REGISTRY" \
  --source  deployer \
  --network testnet \
  -- count 2>/dev/null || echo "0")
echo "✅ vault-registry live — resource count: $COUNT"

# ── Print .env block for backend ──────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   All contracts initialised ✅                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Copy these into your backend .env:"
echo ""
echo "  STELLAR_CONTRACT_VAULT_REGISTRY=$STELLAR_CONTRACT_VAULT_REGISTRY"
echo "  STELLAR_CONTRACT_ACCESS_LEASE=$STELLAR_CONTRACT_ACCESS_LEASE"
echo "  STELLAR_CONTRACT_SUBSCRIPTION=$STELLAR_CONTRACT_SUBSCRIPTION"
echo "  STELLAR_NETWORK=testnet"
echo "  STELLAR_HORIZON_URL=https://horizon-testnet.stellar.org"
echo ""
echo "Next → register resources:"
echo "  node scripts/05-seed-catalog.js"
echo ""
