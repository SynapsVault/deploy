# SynapsVault — SCF Build Award Submission
## Stellar Community Fund v7

---

## 1. Project Overview

**Project name:** SynapsVault  
**Tagline:** A decentralised marketplace where creators sell paywalled digital resources — paid instantly with Stellar USDC, access enforced by Soroban smart contracts.

**One paragraph:**
SynapsVault is an open marketplace where anyone can publish APIs, datasets, research documents, and AI prompts behind a micropayment wall — and anyone can buy them with one click using their Stellar Freighter wallet. Payment is settled in USDC via the x402 HTTP payment protocol. Access rights are recorded on-chain via three Soroban smart contracts (vault-registry, access-lease, subscription), so any third party can verify a buyer's access without trusting SynapsVault's backend. The platform targets AI developers, researchers, and data publishers who want to monetise their work without a traditional SaaS setup.

---

## 2. Problem

There is no simple, permissionless way to sell a digital resource and get paid instantly in crypto:

1. **Web2 paywalls** (Gumroad, Patreon) — fiat-only, 5–10% fees, centralised takedown risk, no crypto
2. **Roll-your-own contract** — weeks of Rust/Solidity work, no UI, no payment UX
3. **Give it away free** — no monetisation, no incentive to produce quality work

For buyers, there is no standardised way to pay for a resource and get access immediately without account creation, credit card, or KYC.

---

## 3. Solution + Stellar Integration

SynapsVault uses Stellar as the **core settlement and access-control layer** — not an afterthought.

| Feature | Stellar component used |
|---------|----------------------|
| Instant payment | USDC on Stellar + x402 HTTP protocol |
| Wallet connection | Stellar Freighter browser extension |
| Resource registry | Soroban `vault-registry` contract |
| Access proofs | Soroban `access-lease` contract |
| Subscriptions | Soroban `subscription` contract |
| Payment verification | Stellar Horizon API |

**Why Stellar specifically:**
- x402 — the HTTP 402 payment protocol is production-ready on Stellar. No other chain has this.
- USDC — native Circle-issued USDC with sub-cent fees and 5-second finality
- Soroban — cheap, verifiable on-chain access records queryable by any party
- Freighter — polished wallet with a clean JS API

---

## 4. Live Deployments

### Contracts on Stellar Testnet ✅

| Contract | Contract ID | Stellar Expert |
|----------|-------------|----------------|
| vault-registry | `CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H` | [View](https://stellar.expert/explorer/testnet/contract/CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H) |
| access-lease | `CDQZBCEPN6RCJAQLEKB3ZRNLUZXDCCFMVIS6STZNAOEAQLXD3FUBNQGX` | [View](https://stellar.expert/explorer/testnet/contract/CDQZBCEPN6RCJAQLEKB3ZRNLUZXDCCFMVIS6STZNAOEAQLXD3FUBNQGX) |
| subscription | `CCCE6Q6WHDICGMQWXXXMM6X7YDGK3BXU4JNQJNSIA6XQRC52MQL42CD6` | [View](https://stellar.expert/explorer/testnet/contract/CCCE6Q6WHDICGMQWXXXMM6X7YDGK3BXU4JNQJNSIA6XQRC52MQL42CD6) |

Deployed via GitHub Actions CI: [view workflow run](https://github.com/SynapsVault/SynapsVault-contracts/actions)

### GitHub Repositories ✅

| Repo | URL | CI Status |
|------|-----|-----------|
| SynapsVault-frontend | https://github.com/SynapsVault/SynapsVault-frontend | [![CI](https://github.com/SynapsVault/SynapsVault-frontend/actions/workflows/ci.yml/badge.svg)](https://github.com/SynapsVault/SynapsVault-frontend/actions) |
| SynapsVault-backend | https://github.com/SynapsVault/SynapsVault-backend | [![CI](https://github.com/SynapsVault/SynapsVault-backend/actions/workflows/ci.yml/badge.svg)](https://github.com/SynapsVault/SynapsVault-backend/actions) |
| SynapsVault-contracts | https://github.com/SynapsVault/SynapsVault-contracts | [![Deploy](https://github.com/SynapsVault/SynapsVault-contracts/actions/workflows/testnet-deploy.yml/badge.svg)](https://github.com/SynapsVault/SynapsVault-contracts/actions) |

### Backend (in progress)
- Build: ✅ TypeScript compiles successfully
- Database: ✅ Drizzle ORM migrations applied
- Seed: ✅ 2 publishers + 3 resources in DB
- Live deploy: Supabase + Railway (being configured — see Milestone 1)

---

## 5. Architecture

```
Browser (React + Vite)
  │  Stellar Freighter wallet
  │  @x402/fetch — wraps HTTP with USDC payment headers
  ▼
SynapsVault Backend (Express + TypeScript)
  │  POST /resources    — publish resource
  │  GET  /resources    — browse catalog
  │  GET  /resources/:id — x402 paywall → verifies payment → delivers content
  │  GET  /admin/*      — admin panel
  │
  ├── Supabase (PostgreSQL + Storage)
  └── Stellar Horizon + Soroban RPC
        │
        ▼
  Soroban Contracts (Stellar testnet, mainnet at M3)
  ├── vault-registry   → on-chain resource catalog
  ├── access-lease     → time-limited access grants
  └── subscription     → 30-day recurring plans
```

---

## 6. Milestone Plan

### Milestone 1 — Live MVP (Month 1)
**Tranche: 20% · ~$15,000**

- [ ] Backend deployed live (Railway + Supabase)
- [ ] Frontend deployed live (Vercel)
- [ ] Full publish + buy flow working end-to-end with Freighter + x402
- [ ] 10 real resources in catalog from 3+ publishers
- [ ] Every purchase triggers vault-registry on-chain update
- [ ] Mobile-responsive UI

**Done when:** Screencast shows Freighter → buy → content delivered → Stellar Expert confirms transaction

---

### Milestone 2 — Testnet Complete (Month 2–3)
**Tranche: 30% · ~$22,500**

- [ ] access-lease integrated: every purchase creates `is_valid=true` on-chain
- [ ] subscription plans live: buyer subscribes → `is_active=true` on-chain
- [ ] Creator analytics dashboard (revenue chart, access counts)
- [ ] Publisher webhooks (HMAC-signed, retry-backed)
- [ ] 25+ resources, 5+ publishers
- [ ] UX audit with 5 real users, documented fixes

---

### Milestone 3 — Mainnet Launch (Month 4)
**Tranche: 40% · ~$30,000**

- [ ] All 3 contracts deployed to Stellar mainnet
- [ ] Security audit via SDF Audit Bank
- [ ] Audit findings resolved
- [ ] First real USDC purchase on mainnet documented
- [ ] Public launch (Stellar Discord, X/Twitter, ProductHunt)
- [ ] 3 paying publishers, 10 paying buyers, $10+ USDC volume

---

## 7. Budget

**Total requested: $75,000 USD in XLM**

| Category | Hours | Rate | Total |
|---|---|---|---|
| Soroban/Rust development | 120h | $85/h | $10,200 |
| Backend (Node.js/TypeScript) | 160h | $75/h | $12,000 |
| Frontend (React/TypeScript) | 140h | $75/h | $10,500 |
| DevOps + infrastructure | 40h | $70/h | $2,800 |
| UX testing + design | 30h | $60/h | $1,800 |
| Documentation | 30h | $50/h | $1,500 |
| Project management | 40h | $55/h | $2,200 |
| Infrastructure (4 months) | — | — | $1,000 |
| Buffer (15%) | — | — | $6,300 |
| **Total** | **560h** | | **~$48,300** |

*Requesting $75,000 to cover full 4-month team runway at West Africa rates. Submitting below the $150k max reflecting our early but validated stage.*

---

## 8. Team

**Agbadesigner (bolu26)**
- Full-stack developer + designer, Lagos, Nigeria
- 3+ years building Web2 SaaS products
- GitHub: https://github.com/bolu26
- Built all 3 SynapsVault repos end-to-end

*Seeking a Soroban/Rust co-developer for M2–M3.*

---

## 9. Ecosystem Value

1. **x402 adoption** — One of the first production applications of the HTTP 402 payment protocol on Stellar
2. **USDC usage** — Every transaction uses Stellar USDC; more transactions = deeper DEX liquidity
3. **Soroban showcase** — Real-world non-DeFi use case for Soroban (access control, subscriptions)
4. **African creator market** — Nigeria's developers can get paid in USDC instantly; Stripe/PayPal unavailable
5. **Publisher onboarding** — Publishers who join also become Stellar wallet users

---

## 10. Links

| Resource | URL |
|---|---|
| GitHub — Frontend | https://github.com/SynapsVault/SynapsVault-frontend |
| GitHub — Backend | https://github.com/SynapsVault/SynapsVault-backend |
| GitHub — Contracts | https://github.com/SynapsVault/SynapsVault-contracts |
| Deployed contracts | https://github.com/SynapsVault/SynapsVault-contracts/blob/main/deployed/contract-ids.env |
| vault-registry on testnet | https://stellar.expert/explorer/testnet/contract/CBQEIMSRPSRKJJHGOELZTP3CISZVHZ6WPKZTWJMYZXHFXPGHHWFQBD4H |
| access-lease on testnet | https://stellar.expert/explorer/testnet/contract/CDQZBCEPN6RCJAQLEKB3ZRNLUZXDCCFMVIS6STZNAOEAQLXD3FUBNQGX |
| subscription on testnet | https://stellar.expert/explorer/testnet/contract/CCCE6Q6WHDICGMQWXXXMM6X7YDGK3BXU4JNQJNSIA6XQRC52MQL42CD6 |
| Deploy workflow | https://github.com/SynapsVault/SynapsVault-contracts/actions/workflows/testnet-deploy.yml |
| Demo video | [to be recorded — see checklist below] |

---

## 11. What To Do Before Submitting

- [ ] Record 5-min demo video: live site → connect Freighter → buy resource → Stellar Expert confirms
- [ ] Deploy backend to Railway (need SUPABASE_URL + Railway account)
- [ ] Deploy frontend to Vercel (push main branch, connect Vercel)
- [ ] Update `VITE_API_URL` env var in Vercel to point at Railway
- [ ] Submit interest form at https://communityfund.stellar.org/awards

---

*Last updated: July 2026*
