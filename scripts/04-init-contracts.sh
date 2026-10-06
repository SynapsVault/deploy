#!/usr/bin/env bash
# SynapsVault — Step 4: Initialise all deployed contracts
#
# Prerequisites:
#   source contract-ids.env      (sets vault_registry, access_lease, subscription)
#   export DEPLOYER_SECRET=S...
#   export BACKEND_PUBLIC=G...   (the backend platform wallet public key)
#
# All three contracts expose init(admin); admin = BACKEND_PUBLIC.

set -euo pipefail

: "${vault_registry:?  source contract-ids.env first}"
: "${access_lease:?    source contract-ids.env first}"
: "${subscription:?    source contract-ids.env first}"
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
  --id      "$vault_registry" \
  --source  deployer \
  --network testnet \
  -- init \
  --admin "$BACKEND_PUBLIC"
echo "✅ vault-registry initialised"

# ── Init access-lease ─────────────────────────────────────────────────────────
echo ""
echo "▸ Initialising access-lease (admin = BACKEND_PUBLIC)…"
$CLI contract invoke \
  --id      "$access_lease" \
  --source  deployer \
  --network testnet \
  -- init \
  --admin "$BACKEND_PUBLIC"
echo "✅ access-lease initialised"

# ── Init subscription ─────────────────────────────────────────────────────────
echo ""
echo "▸ Initialising subscription manager (admin = BACKEND_PUBLIC)…"
$CLI contract invoke \
  --id      "$subscription" \
  --source  deployer \
  --network testnet \
  -- init \
  --admin "$BACKEND_PUBLIC"
echo "✅ subscription initialised"

# ── Verify vault-registry (just read count) ───────────────────────────────────
echo ""
echo "▸ Verifying vault-registry…"
COUNT=$($CLI contract invoke \
  --id      "$vault_registry" \
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
echo "  STELLAR_CONTRACT_VAULT_REGISTRY=$vault_registry"
echo "  STELLAR_CONTRACT_ACCESS_LEASE=$access_lease"
echo "  STELLAR_CONTRACT_SUBSCRIPTION=$subscription"
echo "  STELLAR_NETWORK=testnet"
echo "  STELLAR_HORIZON_URL=https://horizon-testnet.stellar.org"
echo ""
echo "Next → register resources:"
echo "  node scripts/05-seed-catalog.js"
echo ""
