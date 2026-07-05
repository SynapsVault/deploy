# AtriumMind Backend — Full Deployment Guide
## Supabase + Railway (both free tier, ~20 minutes total)

---

## What you'll have at the end

- A live backend API at `https://your-app.up.railway.app`
- A Postgres database on Supabase (free, 500 MB)
- File storage on Supabase (free, 1 GB)
- Auto-deploy whenever you push to `main`

---

## Part 1 — Supabase (database + storage)
**Time: ~8 minutes**

### Step 1.1 — Create a Supabase account

1. Go to **[supabase.com](https://supabase.com)**
2. Click **Start your project** → sign up with GitHub (easiest)
3. You'll land on your Supabase dashboard

---

### Step 1.2 — Create a new project

1. Click **New project**
2. Fill in:
   - **Name:** `atriumind-testnet`
   - **Database Password:** choose a strong password — **write it down, you'll need it**
   - **Region:** choose the one closest to you (Lagos → `eu-west-2` London or `us-east-1`)
3. Click **Create new project**
4. Wait ~2 minutes for the project to provision (you'll see a spinning loader)

---

### Step 1.3 — Get your Database URL

1. In the left sidebar click **Settings** (gear icon at the bottom)
2. Click **Database**
3. Scroll down to **Connection string**
4. Click the **URI** tab
5. Copy the full connection string — it looks like:
   ```
   postgres://postgres:[YOUR-PASSWORD]@db.abcdefghijkl.supabase.co:5432/postgres
   ```
6. Replace `[YOUR-PASSWORD]` with the password you set in Step 1.2
7. **Save this** — this is your `DATABASE_URL`

> ⚠️ If you forget the password, go to Settings → Database → Reset database password

---

### Step 1.4 — Get your Service Role Key

1. In the left sidebar click **Settings** → **API**
2. Under **Project API keys** find the row labelled **`service_role`**
3. Click the eye icon to reveal it, then copy it
4. **Save this** — this is your `SUPABASE_SERVICE_KEY`

It looks like: `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSJ...`

---

### Step 1.5 — Get your Supabase project URL

1. Still in **Settings → API**
2. Under **Project URL** copy the URL
3. It looks like: `https://abcdefghijkl.supabase.co`
4. **Save this** — this is your `SUPABASE_URL`

---

### Step 1.6 — Create the file storage bucket

1. In the left sidebar click **Storage**
2. Click **New bucket**
3. Name it exactly: `resources`
4. Toggle **Public bucket** to **OFF** (private — access controlled by the backend)
5. Click **Save**

---

## Part 2 — Railway (deploy the backend)
**Time: ~10 minutes**

### Step 2.1 — Create a Railway account

1. Go to **[railway.app](https://railway.app)**
2. Click **Login** → **Login with GitHub**
3. Authorise Railway to access your GitHub account

---

### Step 2.2 — Create a new project

1. From the Railway dashboard click **New Project**
2. Select **Deploy from GitHub repo**
3. If this is your first time, click **Configure GitHub App** and give Railway access to your repositories
4. Search for and select **`bolu26/AtriumMind-backend`**
5. Click **Deploy Now**

Railway will start building automatically using the `Dockerfile` in the repo.

> 💡 The first build takes 3–5 minutes. You can watch the build log in real time.

---

### Step 2.3 — Add a Postgres database

1. While the build runs, click **+ New** in the top right of your project
2. Select **Database** → **Add PostgreSQL**
3. Railway creates a managed Postgres instance and automatically sets `DATABASE_URL` in your service — **but** we'll override it with Supabase's URL in the next step

---

### Step 2.4 — Set environment variables

This is the most important step. Click on your **AtriumMind-backend** service (the box in the project), then click the **Variables** tab.

Add each variable below. Click **+ New Variable** for each one.

---

#### 🔴 Required — must set these or the server won't start

| Variable | Value | Where to get it |
|---|---|---|
| `DATABASE_URL` | `postgres://postgres:[PASSWORD]@db.[REF].supabase.co:5432/postgres` | Supabase → Settings → Database → Connection string (URI) |
| `SUPABASE_URL` | `https://[REF].supabase.co` | Supabase → Settings → API → Project URL |
| `SUPABASE_SERVICE_KEY` | `eyJ...` (long JWT token) | Supabase → Settings → API → service_role |
| `SUPABASE_STORAGE_BUCKET` | `resources` | You created this in Step 1.6 |
| `STELLAR_NETWORK` | `testnet` | Fixed value |
| `NETWORK` | `testnet` | Fixed value |
| `SOROBAN_RPC_URL` | `https://soroban-testnet.stellar.org` | Fixed value |
| `USDC_CONTRACT_ID` | `CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA` | Fixed — testnet USDC |
| `PAY_TO` | `GCK7ALS7EP5DQG4UZMON3XTNUE7SSIW27XW24UOLXDHBOHWEWIGZVPZF` | Your BACKEND wallet public key |
| `AGENT_SECRET_KEY` | `SD52YGCD2IS7BS7ULV5VKGHXIJAJUMQJV6M3M34Z2GNAPSYBDUQHCOLX` | Your BACKEND wallet secret key |
| `REGISTRY_SECRET_KEY` | `SD52YGCD2IS7BS7ULV5VKGHXIJAJUMQJV6M3M34Z2GNAPSYBDUQHCOLX` | Same as AGENT_SECRET_KEY |
| `VAULT_REGISTRY_CONTRACT_ID` | `CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H` | Deployed contract |
| `REGISTRY_CONTRACT_ID` | `CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H` | Same as above |
| `OPENROUTER_API_KEY` | Get a free key at [openrouter.ai](https://openrouter.ai) | Free tier available |
| `ADMIN_API_KEY` | `atrium-admin-2025-xK9mP3nQ8rL2vB7s` | Keep this secret |

---

#### 🟡 Optional but recommended

| Variable | Value | Notes |
|---|---|---|
| `NODE_ENV` | `production` | Enables production optimisations |
| `PORT` | `3000` | Railway sets this automatically too |
| `ALLOWED_ORIGINS` | `https://your-frontend.vercel.app` | Set after you have your Vercel URL |
| `FACILITATOR_URL` | `https://www.x402.org/facilitator` | Default x402 facilitator |
| `STELLAR_HORIZON_URL` | `https://horizon-testnet.stellar.org` | Already defaulted |

---

#### Copy-paste block (fill in the blanks marked with `← FILL IN`)

```
DATABASE_URL=postgres://postgres:[YOUR-DB-PASSWORD]@db.[YOUR-REF].supabase.co:5432/postgres   ← FILL IN
SUPABASE_URL=https://[YOUR-REF].supabase.co   ← FILL IN
SUPABASE_SERVICE_KEY=eyJ...   ← FILL IN (from Supabase API settings)
SUPABASE_STORAGE_BUCKET=resources
STELLAR_NETWORK=testnet
NETWORK=testnet
SOROBAN_RPC_URL=https://soroban-testnet.stellar.org
USDC_CONTRACT_ID=CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA
PAY_TO=GCK7ALS7EP5DQG4UZMON3XTNUE7SSIW27XW24UOLXDHBOHWEWIGZVPZF
AGENT_SECRET_KEY=SD52YGCD2IS7BS7ULV5VKGHXIJAJUMQJV6M3M34Z2GNAPSYBDUQHCOLX
REGISTRY_SECRET_KEY=SD52YGCD2IS7BS7ULV5VKGHXIJAJUMQJV6M3M34Z2GNAPSYBDUQHCOLX
VAULT_REGISTRY_CONTRACT_ID=CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H
REGISTRY_CONTRACT_ID=CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H
OPENROUTER_API_KEY=sk-or-...   ← FILL IN (get free at openrouter.ai)
ADMIN_API_KEY=atrium-admin-2025-xK9mP3nQ8rL2vB7s
NODE_ENV=production
PORT=3000
FACILITATOR_URL=https://www.x402.org/facilitator
```

After adding all variables, Railway will **automatically redeploy**.

---

### Step 2.5 — Run database migrations

The database is empty. You need to apply the schema.

1. Click on your **AtriumMind-backend** service
2. Click the **Settings** tab
3. Scroll to **Deploy** → find **Custom Start Command** — leave it as is (uses Dockerfile CMD)
4. Now open the **Shell** tab (or click the terminal icon)
5. Run this command:

```bash
for f in $(ls /app/drizzle/*.sql | sort); do
  echo "Applying $f..."
  node -e "
const { Pool } = require('pg');
const fs = require('fs');
const pool = new Pool({ connectionString: process.env.DATABASE_URL });
pool.query(fs.readFileSync('$f', 'utf8'))
  .then(() => { console.log('OK'); pool.end(); })
  .catch(e => { console.error(e.message); pool.end(); process.exit(0); });
  "
done
echo "All migrations done"
```

> 💡 Alternatively, you can connect to the Supabase database directly using **Supabase → SQL Editor** and run each file in `drizzle/` one by one.

---

### Step 2.6 — Get your Railway URL

1. Click on your service
2. Click the **Settings** tab → **Networking** → **Generate Domain**
3. Railway gives you a URL like: `atriumind-backend-production.up.railway.app`
4. **Save this** — you'll need it for the frontend

---

### Step 2.7 — Verify the deployment

Open your browser and visit these URLs (replace with your Railway domain):

```
# Health check — should return {"status":"ok",...}
https://your-app.up.railway.app/health

# Catalog — should return {"resources":[],...} (empty until seeded)
https://your-app.up.railway.app/resources

# Admin stats — needs header
curl https://your-app.up.railway.app/admin/stats \
  -H "X-Admin-Key: atrium-admin-2025-xK9mP3nQ8rL2vB7s"
```

If `/health` returns `{"status":"ok"}` — your backend is live. ✅

---

## Part 3 — Seed the catalog

Now add the 3 real resources to the catalog.

### Step 3.1 — Create Publisher 1

```bash
curl -X POST https://your-app.up.railway.app/publishers \
  -H "Content-Type: application/json" \
  -d '{
    "name": "AtriumMind Research Lab",
    "email": "research@atriumind.demo",
    "walletAddress": "GDEJJLXV2CNHF5HEGX34MU4G6L4PRVUAGD4ANF77ZDYTQJKSDSDYVVI6"
  }'
```

Copy the `apiKey` from the response. It looks like `ak_...`. **Save it.**

---

### Step 3.2 — Create Publisher 2

```bash
curl -X POST https://your-app.up.railway.app/publishers \
  -H "Content-Type: application/json" \
  -d '{
    "name": "AtriumMind Data Studio",
    "email": "data@atriumind.demo",
    "walletAddress": "GBXL7OEOSVNSESHD7Q2BYVVA2KPQLSSIRLDSY6HFNYPXHCEBKPNCJQKX"
  }'
```

Copy and save this `apiKey` too.

---

### Step 3.3 — Publish 3 resources

Replace `PUB1_KEY` and `PUB2_KEY` with the API keys from above.

```bash
# Resource 1 — Soroban Smart Contract Patterns
curl -X POST https://your-app.up.railway.app/resources \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer PUB1_KEY" \
  -d '{
    "title": "Stellar Soroban Smart Contract Patterns (2025)",
    "description": "Production-tested Soroban patterns: access control, time-locks, circuit breakers, multi-sig. Annotated Rust source for each.",
    "price": "0.50",
    "externalUrl": "https://developers.stellar.org/docs/build/smart-contracts/example-contracts"
  }'

# Resource 2 — Stellar Analytics Dataset
curl -X POST https://your-app.up.railway.app/resources \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer PUB2_KEY" \
  -d '{
    "title": "Stellar Network Analytics — Q1 2025",
    "description": "90 days of Stellar on-chain metrics: daily active accounts, payment volume, DEX trades, Soroban invocations. CSV format.",
    "price": "1.00",
    "externalUrl": "https://dashboard.stellar.org"
  }'

# Resource 3 — x402 Integration Guide
curl -X POST https://your-app.up.railway.app/resources \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer PUB1_KEY" \
  -d '{
    "title": "x402 HTTP Payment Protocol — Integration Guide",
    "description": "Step-by-step x402 integration: server middleware, USDC settlement, receipt verification. Node.js + React examples.",
    "price": "0.25",
    "externalUrl": "https://github.com/x402-org/x402"
  }'
```

---

### Step 3.4 — Verify the catalog

```bash
curl https://your-app.up.railway.app/resources
```

You should see 3 resources in the response. ✅

---

## Part 4 — Connect the frontend

### Step 4.1 — Go to your Vercel project

1. Go to **[vercel.com](https://vercel.com)** → your AtriumMind-frontend project
2. Click **Settings** → **Environment Variables**

### Step 4.2 — Update VITE_API_URL

Find the `VITE_API_URL` variable (or add it if missing):

| Variable | Value |
|---|---|
| `VITE_API_URL` | `https://your-app.up.railway.app` |

### Step 4.3 — Redeploy

1. Click **Deployments** tab
2. Click the three dots on the latest deployment → **Redeploy**
3. Wait ~1 minute

Your frontend now talks to the live backend. Open `https://your-frontend.vercel.app` — you should see 3 resources in the catalog.

---

## Part 5 — Final checks

Run these to confirm everything works end-to-end:

```bash
BACKEND="https://your-app.up.railway.app"
ADMIN_KEY="atrium-admin-2025-xK9mP3nQ8rL2vB7s"

echo "1. Health check"
curl -s $BACKEND/health | python3 -m json.tool

echo "2. Catalog"
curl -s $BACKEND/resources | python3 -c "
import sys,json
d=json.load(sys.stdin)
items=d.get('resources',d.get('data',[]))
print(f'  {len(items)} resources in catalog')
for r in items: print(f'  - {r[\"title\"]} @ {r[\"price\"]} USDC')
"

echo "3. Admin stats"
curl -s $BACKEND/admin/stats -H "X-Admin-Key: $ADMIN_KEY" | python3 -m json.tool

echo "4. x402 paywall blocks unauthenticated access"
CODE=$(curl -s -o /dev/null -w "%{http_code}" $BACKEND/resources/res_001/access)
echo "  Paywall returns HTTP $CODE (expected 402)"
```

---

## Summary of what you have

| Component | Status | URL |
|---|---|---|
| Soroban contracts | ✅ Live on testnet | stellar.expert (see below) |
| Backend API | ✅ Live | `https://your-app.up.railway.app` |
| Database | ✅ Supabase Postgres | Managed |
| File storage | ✅ Supabase Storage | `resources` bucket |
| Catalog | ✅ 3 resources | `/resources` |
| Frontend | ✅ Vercel | `https://your-frontend.vercel.app` |

### Contract IDs (copy these into your SCF submission)

```
vault-registry: CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H
access-lease:   CDQZBCEPN6RCJAQLEKB3ZRNLUZXDCCFMVIS6STZNAOEAQLXD3FUBNQGX
subscription:   CCCE6Q6WHDICGMQWXXXMM6X7YDGK3BXU4JNQJNSIA6XQRC52MQL42CD6
```

### Stellar Expert links (put these in your SCF submission)

- [vault-registry](https://stellar.expert/explorer/testnet/contract/CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H)
- [access-lease](https://stellar.expert/explorer/testnet/contract/CDQZBCEPN6RCJAQLEKB3ZRNLUZXDCCFMVIS6STZNAOEAQLXD3FUBNQGX)
- [subscription](https://stellar.expert/explorer/testnet/contract/CCCE6Q6WHDICGMQWXXXMM6X7YDGK3BXU4JNQJNSIA6XQRC52MQL42CD6)

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Railway build fails | Check the build log — usually a missing env var or npm install error |
| `config_invalid` in server log | A required env var is missing — check the list in Part 2 again |
| `/health` returns 502 | Server crashed on startup — open Railway → your service → Logs |
| Database connection error | Check `DATABASE_URL` — make sure the password is correct and not URL-encoded twice |
| Supabase connection refused | Supabase free tier sleeps after inactivity — visit the dashboard to wake it |
| `curl: (7) Failed to connect` | The service isn't running — check Logs in Railway |
| Publishers 409 conflict | Publisher email already exists — use a different email or skip |
| Resources publish fails | Check that your `Authorization: Bearer` key is correct |

---

*If you get stuck on any step, open an issue at https://github.com/bolu26/AtriumMind-backend/issues*
