# Deploy SynapsVault Backend to Railway (Free Tier)

Railway gives you a free $5/month credit — enough to run the backend 24/7 for testnet demos.

> **Other deployment paths**
> - **Local development / self-hosted:** see [docker-compose.yml](../docker-compose.yml) and the local setup notes in [README.md](../README.md).
> - **Production (Kubernetes):** see [docs/DEPLOYMENT.md](./DEPLOYMENT.md) for the Kubernetes manifests, scaling, and production hardening guidance.
> - **Database migrations & rollback:** see [docs/DATABASE-ROLLBACK.md](./DATABASE-ROLLBACK.md) for rollback procedures. This guide only covers applying forward migrations.

## 1. Prerequisites

- Railway account at [railway.app](https://railway.app) (GitHub login)
- `SynapsVault-backend` pushed to `github.com/SynapsVault/backend` ✅ (already done)
- Supabase project for the database (free tier at [supabase.com](https://supabase.com))

---

## 2. Set up Supabase (database)

1. Go to [supabase.com](https://supabase.com) → New project
2. Name it `synapsvault-testnet`, choose any region
3. Copy the **Connection string** (Settings → Database → Connection string → URI mode)
   - Format: `postgres://postgres:[YOUR-DB-PASSWORD]@db.[ref].supabase.co:5432/postgres`
4. Copy the **Service Role Key** (Settings → API → `service_role`)

---

## 3. Deploy to Railway

### Option A — Railway Dashboard (easiest)

1. [railway.app/new](https://railway.app/new) → **Deploy from GitHub repo**
2. Choose `SynapsVault/backend`
3. Railway auto-detects the `Dockerfile` and builds it
4. Go to **Settings → Domains** → **Generate Domain**
   - You'll get a URL like `synapsvault-backend-production.up.railway.app`

### Option B — Railway CLI

```bash
npm install -g @railway/cli
railway login
railway init          # link to new project
railway up            # deploy from current directory
railway domain        # get your public URL
```

---

## 4. Set environment variables

> See [docs/ENVIRONMENT-VARIABLES.md](./ENVIRONMENT-VARIABLES.md) for the full reference of every variable, defaults, and required/optional status.

In Railway dashboard → your service → **Variables**, add:

```env
# Database
DATABASE_URL=postgres://postgres:[YOUR-DB-PASSWORD]@db.[ref].supabase.co:5432/postgres

# Supabase (for file storage)
SUPABASE_URL=https://[ref].supabase.co
SUPABASE_SERVICE_ROLE_KEY=eyJ...your_service_role_key

# Stellar
STELLAR_NETWORK=testnet
STELLAR_HORIZON_URL=https://horizon-testnet.stellar.org
STELLAR_CONTRACT_VAULT_REGISTRY=[from contract-ids.env]
STELLAR_CONTRACT_ACCESS_LEASE=[from contract-ids.env]
STELLAR_CONTRACT_SUBSCRIPTION=[from contract-ids.env]
STELLAR_SECRET_KEY=[BACKEND wallet secret key]

# Security
ADMIN_API_KEY=[generate: openssl rand -hex 32]

# CORS — allow your Vercel frontend
ALLOWED_ORIGINS=https://[your-app].vercel.app,http://localhost:5173

NODE_ENV=production
PORT=3000
```

---

## 5. Run database migrations

> This section covers **forward migrations only**. For rollback procedures (failed migration, bad deploy, data recovery), see [docs/DATABASE-ROLLBACK.md](./DATABASE-ROLLBACK.md).

After deploy, open Railway **Shell** tab:

```bash
node -e "
const { drizzle } = require('drizzle-orm/node-postgres');
const { migrate } = require('drizzle-orm/node-postgres/migrator');
const { Pool } = require('pg');
const pool = new Pool({ connectionString: process.env.DATABASE_URL });
migrate(drizzle(pool), { migrationsFolder: './drizzle' }).then(() => {
  console.log('Migrations done'); process.exit(0);
}).catch(err => { console.error(err); process.exit(1); });
"
```

Or via the npm script (if you add one to package.json):
```bash
pnpm drizzle-kit migrate
```

---

## 6. Verify deployment

> For ongoing health checks, metrics, and alerting, see [docs/MONITORING.md](./MONITORING.md).

```bash
# Health check
curl https://[your-app].up.railway.app/health

# Should return:
# {"status":"ok","version":"...","uptime":...}

# Catalog (empty at first)
curl https://[your-app].up.railway.app/resources

# Admin stats
curl https://[your-app].up.railway.app/admin/stats \
  -H "X-Admin-Key: your_admin_key"
```

---

## 7. Connect frontend

Update your Vercel environment variables:

```env
VITE_API_URL=https://[your-app].up.railway.app
```

Redeploy frontend → Vercel dashboard → **Redeploy**.

---

## 8. Seed the catalog

```bash
BACKEND_URL=https://[your-app].up.railway.app \
node scripts/05-seed-catalog.js
```

---

## Estimated costs (testnet phase)

| Service | Plan | Monthly cost |
|---------|------|-------------|
| Railway | Hobby (free $5 credit) | $0 |
| Supabase | Free tier (500 MB DB, 1 GB storage) | $0 |
| Vercel | Hobby (free) | $0 |
| **Total** | | **$0** |

The free tiers are sufficient for an SCF testnet demo with <100 daily active users.
