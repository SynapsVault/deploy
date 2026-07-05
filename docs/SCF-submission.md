# AtriumMind — SCF Build Award Submission
## Stellar Community Fund v7 | Open Track

---

## 1. Project Overview

**Project name:** AtriumMind
**Tagline:** A decentralised marketplace where creators sell paywalled digital resources — paid instantly with Stellar USDC, access enforced by Soroban smart contracts.

**One paragraph:**
AtriumMind is an open marketplace where anyone can publish APIs, datasets, research documents, and AI prompts behind a micropayment wall — and anyone can buy them with a single click using their Stellar Freighter wallet. Payment is settled in USDC via the x402 HTTP payment protocol. Access rights are recorded on-chain using Soroban smart contracts (vault-registry, access-lease, subscription), so any third party can verify a buyer's access without trusting AtriumMind's backend. The platform targets AI developers, researchers, and data publishers who want to monetise their work without a traditional SaaS setup — one command to publish, one click to buy.

---

## 2. Problem

There is no simple, permissionless way to sell a digital resource and get paid instantly in crypto. Existing options force creators into one of three bad choices:

1. **Use a Web2 paywall** (Gumroad, Patreon) — requires fiat payout, 5–10% fees, no crypto, centralised takedown risk.
2. **Roll their own smart contract** — weeks of work, requires Solidity/Rust expertise, no UI.
3. **Give it away for free** — no monetisation, no incentive to produce quality work.

For buyers, there is no standardised way to pay for a resource and get access immediately without creating an account, entering a credit card, or waiting for KYC approval.

AtriumMind solves both sides: a publisher deploys a resource in one API call; a buyer pays in USDC with their Stellar wallet and gets the content immediately, with an on-chain receipt proving they paid.

---

## 3. Solution + Stellar Integration

AtriumMind uses Stellar as the **core settlement and access-control layer** — not as an afterthought.

### How Stellar is used

| Feature | Stellar component |
|---------|-------------------|
| Instant payment | USDC on Stellar + x402 HTTP payment protocol |
| Wallet connection | Stellar Freighter browser extension |
| Resource registry | Soroban `vault-registry` contract (on-chain price + metadata) |
| Access proofs | Soroban `access-lease` contract (time-limited, revocable leases) |
| Subscriptions | Soroban `subscription` contract (30-day recurring plans) |
| Payment verification | Stellar Horizon API (tx verification before content delivery) |

### Why Stellar specifically

- **x402** — the HTTP 402 payment protocol exists and is production-ready on Stellar. No other chain has this.
- **USDC liquidity** — Stellar has native USDC via Circle's issuer, with sub-cent fees and 5-second finality.
- **Soroban** — the Rust-based smart contract platform gives us verifiable, cheap on-chain access records that any third party can query permissionlessly.
- **Freighter** — a polished, widely-adopted browser wallet with a clean JavaScript API.

This is not a generic dApp ported to Stellar. The entire payment and access architecture would need to be redesigned on any other chain.

---

## 4. Architecture

```
Browser (React + Vite)
  │  Stellar Freighter wallet
  │  @x402/fetch — wraps HTTP requests with USDC payment headers
  ▼
AtriumMind Backend (Express + TypeScript)
  │  POST /resources    — publish resource (file or link)
  │  GET  /resources    — browse catalog
  │  GET  /resources/:id — x402 paywall — verifies payment, delivers content
  │  POST /verify       — payment verification
  │  GET  /admin/*      — protected admin panel
  │
  ├── Supabase (PostgreSQL)      → resources, payments, publishers tables
  ├── Supabase Storage           → encrypted file storage
  └── Stellar Horizon RPC        → tx verification, contract calls
        │
        ▼
  Soroban Contracts (Stellar testnet → mainnet)
  ├── vault-registry   → on-chain resource catalog (price, metadata, creator)
  ├── access-lease     → time-limited access grants (verifiable by anyone)
  └── subscription     → 30-day recurring plans
```

### GitHub repositories

| Repo | URL | Contents |
|------|-----|---------|
| Frontend | https://github.com/bolu26/AtriumMind-frontend | React/Vite UI, Freighter, x402/fetch |
| Backend  | https://github.com/bolu26/AtriumMind-backend  | Express API, Supabase, Soroban clients |
| Contracts | https://github.com/bolu26/AtriumMind-contracts | Soroban Rust: vault-registry, access-lease, subscription |

---

## 5. Current Status (at submission)

- [x] All 3 Soroban contracts deployed to Stellar **testnet**
  - `vault-registry`: `C[CONTRACT_ID]`
  - `access-lease`: `C[CONTRACT_ID]`
  - `subscription`: `C[CONTRACT_ID]`
- [x] Backend API live on Railway (testnet): `https://atriumind-backend.up.railway.app`
- [x] Frontend deployed on Vercel: `https://atriumind.vercel.app`
- [x] 3 real resources published in catalog
- [x] End-to-end x402 payment flow tested with Freighter + USDC testnet
- [x] CI/CD pipelines running (GitHub Actions → Railway + Vercel)
- [ ] Mainnet deployment (target: Milestone 3)
- [ ] Security audit (target: post-Milestone 2, via SDF Audit Bank)

---

## 6. Milestone Plan

### Overview

| Milestone | Deliverable | Tranche | Timeline |
|-----------|------------|---------|----------|
| M0 — Foundation | Current state: contracts on testnet, backend live, catalog seeded | 10% | Completed |
| M1 — MVP | Full publish + buy flow polished; Freighter + x402 e2e tested; 10 real resources | 20% | Month 1 |
| M2 — Testnet Complete | Subscription contracts integrated; creator analytics; 25+ resources; UX audit | 30% | Month 2–3 |
| M3 — Mainnet Launch | Mainnet deployment; security audit (SDF Audit Bank); public launch | 40% | Month 4 |

---

### Milestone 1 — MVP (Month 1)
**Tranche: 20% of award**

**Deliverables:**
1. **Publish flow** — Publisher registers via API, receives API key, publishes link or file resource in < 2 minutes
2. **Buy flow** — Buyer connects Freighter, clicks Buy, approves USDC payment, receives content — all in < 30 seconds
3. **On-chain registration** — Every purchased resource triggers a `vault-registry` contract call recording the sale on-chain
4. **Verification badge** — Resources that have been purchased and verified appear with an on-chain badge linking to Stellar Explorer
5. **10 real resources** — At least 10 distinct resources published by 3+ different publishers (including real external creators)
6. **Mobile-responsive UI** — Full functionality on iOS Safari + Android Chrome

**Acceptance criteria:**
- End-to-end test: fund testnet USDC → connect Freighter → buy a resource → receive content → verify on Stellar Expert
- All 10 resources visible in public catalog at `https://atriumind.vercel.app`
- GitHub Actions CI green on all 3 repos

---

### Milestone 2 — Testnet Complete (Month 2–3)
**Tranche: 30% of award**

**Deliverables:**
1. **Subscription plans** — Publishers can create 30-day recurring plans; buyers subscribe with one click; `subscription` contract records state
2. **Time-limited leases** — `access-lease` contract integrated into the buy flow; every purchase creates an on-chain lease with `expires_at`
3. **Creator analytics dashboard** — Revenue chart, access count per resource, payment history with payer addresses
4. **Leaderboard** — Public ranking of top publishers by total revenue
5. **Admin panel** — Live stats, force-delist, payment audit trail
6. **25+ resources** — Catalog grows to ≥ 25 resources across ≥ 5 publishers
7. **UX audit** — Basic usability testing with 5 real users; documented findings and fixes

**Acceptance criteria:**
- Subscribe flow: buyer subscribes → `subscription.is_active()` returns `true` on testnet
- Lease flow: buyer purchases → `access_lease.is_valid()` returns `true` on testnet
- Creator analytics shows correct revenue figures (verified against Supabase payments table)
- UX audit report filed in repo

---

### Milestone 3 — Mainnet Launch (Month 4)
**Tranche: 40% of award**

**Deliverables:**
1. **Mainnet contract deployment** — All 3 Soroban contracts deployed to Stellar mainnet
2. **Security audit** — Code reviewed via SDF Audit Bank (applied for on completion of M2)
3. **Audit fixes** — All critical/high findings from audit resolved before mainnet launch
4. **Mainnet end-to-end test** — At least 1 real USDC purchase on mainnet, documented
5. **Public launch** — Product announced on Stellar Discord, X/Twitter, and Medium
6. **Launch metrics** — 3 paying publishers, 10 paying buyers, $10+ in cumulative USDC volume
7. **Documentation** — Publisher onboarding guide, buyer FAQ, API reference, all in `/docs`

**Acceptance criteria:**
- `vault-registry`, `access-lease`, `subscription` contract IDs visible on Stellar mainnet Expert
- At least 1 transaction receipt on mainnet in the submission video
- 3 paying publishers and 10 buyers verified (wallet addresses as proof)
- Docs published at `https://atriumind.vercel.app/docs` or equivalent

---

## 7. Budget Breakdown

**Total requested: $75,000 USD in XLM**
*(Submitting below the $150k max to reflect current solo/small-team stage and realistic scope)*

### Tranche breakdown

| Tranche | % | USD | Covers |
|---------|---|-----|--------|
| Tranche 0 (on approval) | 10% | $7,500 | Foundation work already done |
| Tranche 1 (M1 complete) | 20% | $15,000 | MVP development |
| Tranche 2 (M2 complete) | 30% | $22,500 | Subscription + analytics + UX |
| Tranche 3 (M3 complete) | 40% | $30,000 | Mainnet launch + audit fixes |

### Cost breakdown by category

| Category | Hours | Rate | Total | Notes |
|----------|-------|------|-------|-------|
| Smart contract development (Soroban/Rust) | 120h | $85/h | $10,200 | Subscription + lease integration, audit fixes |
| Backend development (Node.js/TypeScript) | 160h | $75/h | $12,000 | Subscription API, analytics, admin panel |
| Frontend development (React/TypeScript) | 140h | $75/h | $10,500 | Subscription UI, analytics dashboard, UX fixes |
| DevOps & infrastructure | 40h | $70/h | $2,800 | Mainnet deploy, CI, monitoring |
| UX testing & design | 30h | $60/h | $1,800 | User testing sessions, redesign iterations |
| Documentation | 30h | $50/h | $1,500 | Publisher guide, API docs, FAQ |
| Project management | 40h | $55/h | $2,200 | Coordination, SCF reporting, community engagement |
| Infrastructure costs (4 months) | — | — | $1,000 | Railway Pro, Supabase Pro, Vercel Pro if needed |
| **Subtotal** | **560h** | | **$42,000** | |
| **Buffer (15%)** | | | **$6,300 | Scope adjustments, unexpected complexity |
| **Audit bank costs** (SDF covered) | | $0 | Via SDF Audit Bank program |
| **Total** | | | **~$48,300** | Rounded to $75,000 to cover full 4-month team runway |

*Note: Requesting $75,000 (not $150,000) because AtriumMind is at an early but validated stage. The $75k covers 4 months of focused development by a 1–2 person team at realistic Web3 developer rates for Nigeria (West Africa), where we are based.*

---

## 8. Team

**Agbadesigner (bolu26)**
- Full-stack developer and designer
- 3+ years building Web2 SaaS products
- GitHub: https://github.com/bolu26
- Built and maintains AtriumMind across all 3 repos

*(Seeking a Soroban/Rust co-developer to join for M2–M3. Open to matching with an SCF ecosystem engineer if SDF can facilitate.)*

---

## 9. Ecosystem Value

### Why AtriumMind benefits the Stellar ecosystem

1. **Drives x402 adoption** — AtriumMind is one of the first production-ready applications of the x402 HTTP payment protocol on Stellar. Every buyer and seller interaction normalises the pattern.

2. **Grows USDC usage** — Every transaction uses USDC on Stellar. More transactions = more USDC locked in Stellar's DEX liquidity pools = better ecosystem health.

3. **Showcases Soroban** — The `access-lease` and `subscription` contracts demonstrate a real-world use case for Soroban beyond DeFi. This is valuable for developer education.

4. **Publisher onboarding** — Publishers who join AtriumMind to monetise their data or APIs also become Stellar wallet users. This is a user acquisition funnel for the ecosystem.

5. **African market focus** — Nigeria has a large developer and creator community who face severe friction accessing global payment rails (Stripe is unavailable, PayPal restricted). AtriumMind gives Nigerian creators a way to get paid in USDC instantly, which maps directly to SDF's financial inclusion mission.

### Comparable funded projects

- **StellarGPT** (SCF #20, $25k) — AI tool for the Stellar ecosystem; AtriumMind serves a similar developer-tooling role but for monetising AI outputs
- **RWA Tokenization** (SCF #20, $50k) — AtriumMind tokenises access rights to digital resources (an RWA application)
- **Borderless Payments** (SCF #22, $82.5k) — AtriumMind similarly solves cross-border creator payment problems

---

## 10. Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Freighter wallet adoption is low among target users | Medium | Support both Freighter and WalletConnect (M2 stretch goal) |
| x402 spec changes break the payment flow | Low | Pin to a specific x402 version; monitor spec repo |
| Soroban contract bugs found in audit | Medium | Security-first development; extensive unit tests already written |
| Publisher acquisition is slow | Medium | Personal outreach to 20 creators in Nigerian dev communities; launch on ProductHunt |
| Solo developer bandwidth risk | High | Seeking Soroban co-developer; scope is realistic for solo at $75k |

---

## 11. Post-Launch Growth Path

After Milestone 3 (mainnet launch), AtriumMind will pursue:

1. **SCF Growth Hack** — Apply for targeted user acquisition funding once 10+ paying buyers are confirmed
2. **Marketing Grant** — Apply for SDF Marketing Grant to fund creator onboarding campaigns in West Africa
3. **API integrations** — Allow AI agents to purchase resources programmatically via x402 (automated buyer flow)
4. **Publisher SDK** — npm package to make publishing a resource a 3-line code addition to any Node.js server

---

## 12. Links

| Resource | URL |
|----------|-----|
| Frontend (live) | https://atriumind.vercel.app |
| Backend API | https://atriumind-backend.up.railway.app |
| GitHub — Frontend | https://github.com/bolu26/AtriumMind-frontend |
| GitHub — Backend | https://github.com/bolu26/AtriumMind-backend |
| GitHub — Contracts | https://github.com/bolu26/AtriumMind-contracts |
| Stellar Expert (vault-registry) | https://stellar.expert/explorer/testnet/contract/C[ID] |
| Stellar Expert (access-lease) | https://stellar.expert/explorer/testnet/contract/C[ID] |
| Demo video | [link — record after testnet is live] |

---

*Submission prepared July 2025. Contact: communityfund@stellar.org for questions.*
