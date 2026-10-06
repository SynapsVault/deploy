# Environment Variables Reference

This document is the single source of truth for every environment variable used across the backend, frontend, and deployment scripts of this project. It covers purpose, required/optional status, default values, and recommended values per environment (development, staging, production).

> **Security note:** Never commit real secrets to version control. All `.env` files containing secrets must be listed in `.gitignore`. Use your platform's secret manager (GitHub Actions secrets, Vercel/Netlify env vars, AWS Secrets Manager, Doppler, etc.) for staging and production. The `.env.example` template below contains placeholders only.

---

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Database & Supabase](#database--supabase)
3. [Stellar / Soroban Network](#stellar--soroban-network)
4. [Contracts](#contracts)
5. [Secrets & API Keys](#secrets--api-keys)
6. [Server & Runtime](#server--runtime)
7. [Frontend (Vite)](#frontend-vite)
8. [Per-Environment Matrix](#per-environment-matrix)
9. [.env.example Template](#envexample-template)
10. [Security Notes](#security-notes)

---

## Quick Reference

| Variable | Required | Default | Scope |
|---|---|---|---|
| `DATABASE_URL` | Yes | — | Backend |
| `SUPABASE_URL` | Yes | — | Backend / Frontend |
| `SUPABASE_SERVICE_KEY` | Yes | — | Backend |
| `SUPABASE_STORAGE_BUCKET` | No | `uploads` | Backend |
| `STELLAR_NETWORK` | Yes | `testnet` | Backend |
| `NETWORK` | No | `testnet` | Backend / Scripts |
| `SOROBAN_RPC_URL` | Yes | — | Backend |
| `STELLAR_HORIZON_URL` | Yes | — | Backend |
| `USDC_CONTRACT_ID` | Yes | — | Backend |
| `PAY_TO` | Yes | — | Backend |
| `AGENT_SECRET_KEY` | Yes | — | Backend |
| `REGISTRY_SECRET_KEY` | Yes | — | Backend |
| `VAULT_REGISTRY_CONTRACT_ID` | Yes | — | Backend |
| `REGISTRY_CONTRACT_ID` | Yes | — | Backend |
| `STELLAR_CONTRACT_VAULT_REGISTRY` | Yes | — | Backend |
| `STELLAR_CONTRACT_ACCESS_LEASE` | Yes | — | Backend |
| `STELLAR_CONTRACT_SUBSCRIPTION` | Yes | — | Backend |
| `STELLAR_SECRET_KEY` | Yes | — | Backend / Scripts |
| `OPENROUTER_API_KEY` | Yes | — | Backend |
| `ADMIN_API_KEY` | Yes | — | Backend |
| `NODE_ENV` | No | `development` | Backend |
| `PORT` | No | `3000` | Backend |
| `ALLOWED_ORIGINS` | No | `http://localhost:5173` | Backend |
| `FACILITATOR_URL` | Yes | — | Backend |
| `VITE_API_URL` | Yes | `http://localhost:3000` | Frontend |

---

## Database & Supabase

### `DATABASE_URL`
- **Purpose:** PostgreSQL connection string used by the backend ORM / query layer.
- **Required:** Yes
- **Default:** none
- **Format:** `postgresql://<user>:<password>@<host>:<port>/<database>?sslmode=require`
- **Notes:** In production, always use `sslmode=require` and a connection pooler (e.g. Supabase pooler) for serverless deployments.

### `SUPABASE_URL`
- **Purpose:** Base URL of the Supabase project (used by backend and frontend clients).
- **Required:** Yes
- **Default:** none
- **Format:** `https://<project-ref>.supabase.co`

### `SUPABASE_SERVICE_KEY`
- **Purpose:** Supabase service-role key. Grants full admin access to the database and storage. **Backend only.**
- **Required:** Yes
- **Default:** none
- **Notes:** Never expose to the frontend. Never prefix with `VITE_`.

### `SUPABASE_STORAGE_BUCKET`
- **Purpose:** Name of the Supabase Storage bucket used for uploads.
- **Required:** No
- **Default:** `uploads`

---

## Stellar / Soroban Network

### `STELLAR_NETWORK`
- **Purpose:** Selects the Stellar network the backend talks to.
- **Required:** Yes
- **Default:** `testnet`
- **Allowed values:** `testnet`, `mainnet`, `futurenet`, `local`

### `NETWORK`
- **Purpose:** Alias used by deployment scripts and CLI tooling to select the target network.
- **Required:** No
- **Default:** `testnet`
- **Allowed values:** `testnet`, `mainnet`, `local`

### `SOROBAN_RPC_URL`
- **Purpose:** Soroban RPC endpoint used to submit and simulate contract calls.
- **Required:** Yes
- **Default:** none
- **Examples:**
  - Testnet: `https://soroban-testnet.stellar.org`
  - Mainnet: `https://soroban-mainnet.stellar.org`

### `STELLAR_HORIZON_URL`
- **Purpose:** Horizon endpoint used for account, balance, and transaction queries.
- **Required:** Yes
- **Default:** none
- **Examples:**
  - Testnet: `https://horizon-testnet.stellar.org`
  - Mainnet: `https://horizon.stellar.org`

### `USDC_CONTRACT_ID`
- **Purpose:** Contract ID of the USDC token used for payments.
- **Required:** Yes
- **Default:** none
- **Notes:** Testnet and mainnet have different contract IDs. Verify against the official Circle / Stellar documentation before deploying.

---

## Contracts

### `PAY_TO`
- **Purpose:** Stellar account (public key) that receives payments.
- **Required:** Yes
- **Default:** none
- **Format:** `G...` (56-character Stellar public key)

### `VAULT_REGISTRY_CONTRACT_ID`
- **Purpose:** Contract ID of the vault registry contract.
- **Required:** Yes
- **Default:** none

### `REGISTRY_CONTRACT_ID`
- **Purpose:** Contract ID of the primary registry contract.
- **Required:** Yes
- **Default:** none

### `STELLAR_CONTRACT_VAULT_REGISTRY`
- **Purpose:** Contract ID for the vault registry (used by deployment scripts and backend).
- **Required:** Yes
- **Default:** none
- **Notes:** May be identical to `VAULT_REGISTRY_CONTRACT_ID`; keep both for backward compatibility with existing scripts.

### `STELLAR_CONTRACT_ACCESS_LEASE`
- **Purpose:** Contract ID for the access-lease contract.
- **Required:** Yes
- **Default:** none

### `STELLAR_CONTRACT_SUBSCRIPTION`
- **Purpose:** Contract ID for the subscription contract.
- **Required:** Yes
- **Default:** none

---

## Secrets & API Keys

### `AGENT_SECRET_KEY`
- **Purpose:** Stellar secret key (`S...`) used by the agent service to sign transactions.
- **Required:** Yes
- **Default:** none
- **Notes:** Store in a secret manager. Rotate regularly. Never log.

### `REGISTRY_SECRET_KEY`
- **Purpose:** Stellar secret key used to sign registry contract operations.
- **Required:** Yes
- **Default:** none
- **Notes:** Store in a secret manager. Never log.

### `STELLAR_SECRET_KEY`
- **Purpose:** Generic Stellar secret key used by deployment scripts and CLI tooling.
- **Required:** Yes
- **Default:** none
- **Notes:** In CI, inject via GitHub Actions secrets. Never commit.

### `OPENROUTER_API_KEY`
- **Purpose:** API key for OpenRouter (LLM inference).
- **Required:** Yes
- **Default:** none
- **Format:** `sk-or-v1-...`

### `ADMIN_API_KEY`
- **Purpose:** Shared secret used to authenticate admin API requests.
- **Required:** Yes
- **Default:** none
- **Notes:** Generate with a CSPRNG (e.g. `openssl rand -hex 32`). Rotate on any suspected leak.

---

## Server & Runtime

### `NODE_ENV`
- **Purpose:** Node.js runtime mode.
- **Required:** No
- **Default:** `development`
- **Allowed values:** `development`, `test`, `production`

### `PORT`
- **Purpose:** Port the backend HTTP server listens on.
- **Required:** No
- **Default:** `3000`

### `ALLOWED_ORIGINS`
- **Purpose:** Comma-separated list of origins allowed by CORS.
- **Required:** No
- **Default:** `http://localhost:5173`
- **Example:** `https://app.example.com,https://staging.example.com`

### `FACILITATOR_URL`
- **Purpose:** Base URL of the payment facilitator service.
- **Required:** Yes
- **Default:** none
- **Examples:**
  - Development: `http://localhost:4000`
  - Staging: `https://facilitator.staging.example.com`
  - Production: `https://facilitator.example.com`

---

## Frontend (Vite)

### `VITE_API_URL`
- **Purpose:** Base URL of the backend API consumed by the frontend.
- **Required:** Yes
- **Default:** `http://localhost:3000`
- **Notes:** Only variables prefixed with `VITE_` are exposed to the browser bundle. Never put secrets in a `VITE_` variable.

---

## Per-Environment Matrix

| Variable | Development | Staging | Production |
|---|---|---|---|
| `DATABASE_URL` | `postgresql://postgres:postgres@localhost:5432/app` | Supabase pooler URL (staging project) | Supabase pooler URL (prod project, `sslmode=require`) |
| `SUPABASE_URL` | `https://<dev-ref>.supabase.co` | `https://<staging-ref>.supabase.co` | `https://<prod-ref>.supabase.co` |
| `SUPABASE_SERVICE_KEY` | Dev service key | Staging service key | Prod service key (secret manager) |
| `SUPABASE_STORAGE_BUCKET` | `uploads` | `uploads` | `uploads` |
| `STELLAR_NETWORK` | `testnet` | `testnet` | `mainnet` |
| `NETWORK` | `testnet` | `testnet` | `mainnet` |
| `SOROBAN_RPC_URL` | `https://soroban-testnet.stellar.org` | `https://soroban-testnet.stellar.org` | `https://soroban-mainnet.stellar.org` |
| `STELLAR_HORIZON_URL` | `https://horizon-testnet.stellar.org` | `https://horizon-testnet.stellar.org` | `https://horizon.stellar.org` |
| `USDC_CONTRACT_ID` | Testnet USDC contract ID | Testnet USDC contract ID | Mainnet USDC contract ID |
| `PAY_TO` | Dev `G...` account | Staging `G...` account | Prod `G...` account |
| `AGENT_SECRET_KEY` | Dev `S...` key | Staging `S...` key | Prod `S...` key (secret manager) |
| `REGISTRY_SECRET_KEY` | Dev `S...` key | Staging `S...` key | Prod `S...` key (secret manager) |
| `VAULT_REGISTRY_CONTRACT_ID` | Dev contract ID | Staging contract ID | Prod contract ID |
| `REGISTRY_CONTRACT_ID` | Dev contract ID | Staging contract ID | Prod contract ID |
| `STELLAR_CONTRACT_VAULT_REGISTRY` | Dev contract ID | Staging contract ID | Prod contract ID |
| `STELLAR_CONTRACT_ACCESS_LEASE` | Dev contract ID | Staging contract ID | Prod contract ID |
| `STELLAR_CONTRACT_SUBSCRIPTION` | Dev contract ID | Staging contract ID | Prod contract ID |
| `STELLAR_SECRET_KEY` | Dev `S...` key | Staging `S...` key | Prod `S...` key (secret manager) |
| `OPENROUTER_API_KEY` | Dev key | Staging key | Prod key (secret manager) |
| `ADMIN_API_KEY` | Dev random hex | Staging random hex | Prod random hex (secret manager) |
| `NODE_ENV` | `development` | `production` | `production` |
| `PORT` | `3000` | `3000` | `3000` |
| `ALLOWED_ORIGINS` | `http://localhost:5173` | `https://staging.example.com` | `https://app.example.com` |
| `FACILITATOR_URL` | `http://localhost:4000` | `https://facilitator.staging.example.com` | `https://facilitator.example.com` |
| `VITE_API_URL` | `http://localhost:3000` | `https://api.staging.example.com` | `https://api.example.com` |

---

## .env.example Template

Copy this file to `.env` and fill in real values. **Do not commit the resulting `.env`.**

```dotenv
# ---------------------------------------------------------------------------
# Database & Supabase
# ---------------------------------------------------------------------------
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/app
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_SERVICE_KEY=your-supabase-service-role-key
SUPABASE_STORAGE_BUCKET=uploads

# ---------------------------------------------------------------------------
# Stellar / Soroban Network
# ---------------------------------------------------------------------------
STELLAR_NETWORK=testnet
NETWORK=testnet
SOROBAN_RPC_URL=https://soroban-testnet.stellar.org
STELLAR_HORIZON_URL=https://horizon-testnet.stellar.org
USDC_CONTRACT_ID=CXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------
PAY_TO=GXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
VAULT_REGISTRY_CONTRACT_ID=CXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
REGISTRY_CONTRACT_ID=CXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
STELLAR_CONTRACT_VAULT_REGISTRY=CXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
STELLAR_CONTRACT_ACCESS_LEASE=CXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
STELLAR_CONTRACT_SUBSCRIPTION=CXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

# ---------------------------------------------------------------------------
# Secrets & API Keys
# ---------------------------------------------------------------------------
AGENT_SECRET_KEY=SXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
REGISTRY_SECRET_KEY=SXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
STELLAR_SECRET_KEY=SXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
OPENROUTER_API_KEY=sk-or-v1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ADMIN_API_KEY=replace-with-openssl-rand-hex-32

# ---------------------------------------------------------------------------
# Server & Runtime
# ---------------------------------------------------------------------------
NODE_ENV=development
PORT=3000
ALLOWED_ORIGINS=http://localhost:5173
FACILITATOR_URL=http://localhost:4000

# ---------------------------------------------------------------------------
# Frontend (Vite)
# ---------------------------------------------------------------------------
VITE_API_URL=http://localhost:3000
```

---

## Security Notes

- **Never commit secrets.** Add `.env`, `.env.*` (except `.env.example`), and any secret-bearing files to `.gitignore`.
- **Use a secret manager** for staging and production (GitHub Actions secrets, AWS Secrets Manager, Doppler, Vault, etc.). Do not bake secrets into container images or CI logs.
- **Rotate on leak.** If a secret is ever committed or logged, rotate it immediately — assume it is compromised.
- **Least privilege.** Use separate Supabase projects, Stellar accounts, and API keys per environment. Never reuse production credentials in development.
- **Frontend exposure.** Only variables prefixed with `VITE_` are bundled into the browser. Never place secrets in a `VITE_` variable.
- **CORS.** Keep `ALLOWED_ORIGINS` tight. Avoid `*` in staging and production.
- **Logging.** Redact secret values in logs and error reports. Never print full `S...` Stellar keys or service-role keys.
- **Validation.** The backend should fail fast at startup if any required variable is missing or malformed.