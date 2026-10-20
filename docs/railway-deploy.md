# Deploy SynapsVault Backend to Railway

> **This is the canonical Railway deployment guide.**
> All other mentions of Railway in this repository link here.
>
> Other deployment targets:
> - **Local (Docker Compose):** see [README.md](../README.md#local-development-docker-compose) and [`docker-compose.yml`](../docker-compose.yml).
> - **Production (Kubernetes):** see [`docs/DEPLOY-KUBERNETES.md`](./DEPLOY-KUBERNETES.md).
> - **Database migrations and rollback:** see [`docs/DATABASE-ROLLBACK.md`](./DATABASE-ROLLBACK.md).

---

## Overview

**Total time: ~20 minutes** (mostly waiting for the first build)

```
Part 1  Set up Supabase              (~8 min)
Part 2  Deploy backend to Railway    (~10 min)
Part 3  Run database migrations      (~2 min)
Part 4  Verify and connect frontend  (~2 min)
```

At the end you will have:

- A live backend API at `https://<your-app>.up.railway.app`
- A Postgres database on Supabase (free tier, 500 MB)
- File storage on Supabase (free, 1 GB)
- Auto-deploy on every push to `main`

---

## Prerequisites

- [ ] Railway account at [railway.app](https://railway.app) — sign in with GitHub
- [ ] `SynapsVault/backend` pushed to GitHub ✅
- [ ] Supabase account at [supabase.com](https://supabase.com)
- [ ] Contract IDs from `contract-ids.env` (output of Step 3 in [README.md](../README.md))
- [ ] Backend wallet keypair (`STELLAR_SECRET_KEY` / `STELLAR_PUBLIC_KEY`)
- [ ] Environment variables validated:
  ```bash
  cp .env.example .env   # fill in your values
  node scripts/check-env.js --target railway
  ```

---

## Part 1 — Supabase (database + storage)

### 1.1 Create a project

1. [supabase.com](https://supabase.com) → **New project**
2. Name: `synapsvault-testnet`, choose a region close to your users
3. Set a strong database password — **write it down**
4. Wait ~2 minutes for provisioning

### 1.2 Get your Database URL

1. Left sidebar → **Settings** → **Database**
2. Scroll to **Connection string** → select the **URI** tab
3. Copy the string:
   ```
   postgres://postgres:[YOUR-DB-PASSWORD]@db.[ref].supabase.co:5432/postgres
   ```
4. This is your `DATABASE_URL`.

> If you forget the password: Settings → Database → **Reset database password**.

### 1.3 Get your API credentials

1. Left sidebar → **Settings** → **API**
2. Copy **Project URL** → this is `SUPABASE_URL`
3. Reveal and copy `service_role` key → this is `SUPABASE_SERVICE_KEY`

### 1.4 Create the storage bucket

1. Left sidebar → **Storage** → **New bucket**
2. Name: `resources`
3. Toggle **Public bucket** → **OFF** (access controlled by the backend)
4. Click **Save**

---

## Part 2 — Deploy to Railway

### Option A — Dashboard (easiest)

1. [railway.app/new](https://railway.app/new) → **Deploy from GitHub repo**
2. Select `SynapsVault/backend`
3. Railway detects the `Dockerfile` and starts building automatically
4. Go to **Settings → Domains → Generate Domain** once the build finishes
   - URL format: `synapsvault-backend-production.up.railway.app`

### Option B — Railway CLI

```bash
npm install -g @railway/cli
railway login
railway init      # link or create a project
railway up        # deploy from the current directory
railway domain    # print your public URL
```

### Set environment variables

In the Railway dashboard → your service → **Variables**, add every variable
from the table below.

> See [docs/ENVIRONMENT-VARIABLES.md](./ENVIRONMENT-VARIABLES.md) for the
> complete reference including defaults, validation rules, and optional
> variables. The table below covers the variables required for this deployment.

#### Required — the server will not start without these

| Variable | Value | Source |
|----------|-------|--------|
| `DATABASE_URL` | `postgres://postgres:[PASSWORD]@db.[ref].supabase.co:5432/postgres` | Supabase → Settings → Database → Connection string |
| `SUPABASE_URL` | `https://[ref].supabase.co` | Supabase → Settings → API → Project URL |
| `SUPABASE_SERVICE_KEY` | `eyJ...` (JWT) | Supabase → Settings → API → `service_role` |
| `SUPABASE_STORAGE_BUCKET` | `resources` | Created in Part 1.4 |
| `STELLAR_NETWORK` | `testnet` | Fixed value |
| `NETWORK` | `testnet` | Fixed value |
| `SOROBAN_RPC_URL` | `https://soroban-testnet.stellar.org` | Fixed value |
| `USDC_CONTRACT_ID` | `CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA` | Fixed — testnet USDC |
| `PAY_TO` | `G...` | Your BACKEND wallet public key |
| `AGENT_SECRET_KEY` | `S...` | Your BACKEND wallet secret key |
| `REGISTRY_SECRET_KEY` | `S...` | Same as `AGENT_SECRET_KEY` |
| `STELLAR_CONTRACT_VAULT_REGISTRY` | `C...` | `contract-ids.env` |
| `STELLAR_CONTRACT_ACCESS_LEASE` | `C...` | `contract-ids.env` |
| `STELLAR_CONTRACT_SUBSCRIPTION` | `C...` | `contract-ids.env` |
| `OPENROUTER_API_KEY` | `sk-or-...` | [openrouter.ai](https://openrouter.ai) (free tier available) |
| `ADMIN_API_KEY` | random hex | `openssl rand -hex 32` |

#### Optional but recommended

| Variable | Value | Notes |
|----------|-------|-------|
| `NODE_ENV` | `production` | Enables production optimisations |
| `PORT` | `3000` | Railway sets this automatically |
| `ALLOWED_ORIGINS` | `https://[your-app].vercel.app` | Set after you have your Vercel URL |
| `FACILITATOR_URL` | `https://www.x402.org/facilitator` | Default x402 facilitator |
| `STELLAR_HORIZON_URL` | `https://horizon-testnet.stellar.org` | Already defaulted in code |

#### Copy-paste block (replace `← FILL IN` values)

```env
DATABASE_URL=postgres://postgres:[YOUR-DB-PASSWORD]@db.[YOUR-REF].supabase.co:5432/postgres
SUPABASE_URL=https://[YOUR-REF].supabase.co
SUPABASE_SERVICE_KEY=eyJ...
SUPABASE_STORAGE_BUCKET=resources
STELLAR_NETWORK=testnet
NETWORK=testnet
SOROBAN_RPC_URL=https://soroban-testnet.stellar.org
USDC_CONTRACT_ID=CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA
PAY_TO=G...
AGENT_SECRET_KEY=S...
REGISTRY_SECRET_KEY=S...
STELLAR_CONTRACT_VAULT_REGISTRY=C...
STELLAR_CONTRACT_ACCESS_LEASE=C...
STELLAR_CONTRACT_SUBSCRIPTION=C...
OPENROUTER_API_KEY=sk-or-...
ADMIN_API_KEY=← FILL IN (openssl rand -hex 32)
NODE_ENV=production
PORT=3000
FACILITATOR_URL=https://www.x402.org/facilitator
```

After adding all variables Railway automatically redeploys.

---

## Part 3 — Run database migrations

> This section covers **forward migrations only**. For rollback procedures, see
> [docs/DATABASE-ROLLBACK.md](./DATABASE-ROLLBACK.md).

1. In the Railway dashboard, click on your service → **Shell** tab
2. Run:
   ```bash
   pnpm drizzle-kit migrate
   ```

Alternatively, connect to Supabase directly (Settings → SQL Editor) and apply
each file in the `drizzle/` directory in order.

---

## Part 4 — Verify and connect the frontend

### Verify the backend

```bash
RAILWAY_URL=https://your-app.up.railway.app

# Health check — should return {"status":"ok",...}
curl "$RAILWAY_URL/health"

# Catalog — should return {"resources":[]} until seeded
curl "$RAILWAY_URL/resources"

# Admin stats
curl "$RAILWAY_URL/admin/stats" -H "X-Admin-Key: your_admin_key"
```

If `/health` returns `{"status":"ok"}` the backend is live. ✅

### Connect the frontend

Update your Vercel environment variables:

```env
VITE_API_URL=https://your-app.up.railway.app
```

Redeploy in the Vercel dashboard: **Deployments → latest → Redeploy**.

---

## Seeding the catalog

Run the seed script from the `deploy` repo:

```bash
BACKEND_URL=https://your-app.up.railway.app \
PUBLISHER1_PUBLIC=G[PUBLISHER1] \
PUBLISHER2_PUBLIC=G[PUBLISHER2] \
node scripts/05-seed-catalog.js
```

This idempotently publishes the 3 catalog resources and exits non-zero if any
step fails.

---

## Costs (testnet phase)

| Service | Plan | Monthly cost |
|---------|------|-------------|
| Railway | Hobby ($5 credit) | $0 |
| Supabase | Free tier (500 MB DB, 1 GB storage) | $0 |
| Vercel | Hobby (free) | $0 |
| **Total** | | **$0** |

The free tiers are sufficient for an SCF testnet demo with fewer than 100 daily
active users.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Build fails | Check the Railway build log — usually a missing env var or npm install error |
| `config_invalid` in server log | A required env var is missing — check the variables table above and [docs/ENVIRONMENT-VARIABLES.md](./ENVIRONMENT-VARIABLES.md) |
| `/health` returns 502 | Server crashed on startup — Railway → your service → **Logs** |
| Database connection error | Verify `DATABASE_URL` — ensure the password is not URL-encoded twice |
| Supabase connection refused | The Supabase free tier sleeps after inactivity — open the Supabase dashboard to wake it |
| `curl: (7) Failed to connect` | Service not running — check Railway Logs |
| `REPLACE_ME_*` / `change-me-*` errors | Run `node scripts/check-env.js --target railway` to find unfilled placeholders |
| Migrations fail | Confirm `DATABASE_URL` resolves to the correct Supabase project |

---

## Monitoring

Once the backend is live, set up health-check alerting, dashboards, and
on-call procedures by following [docs/MONITORING.md](./MONITORING.md).
