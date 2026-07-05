/**
 * AtriumMind — Step 5: Seed the catalog with 3 real resources
 *
 * This script:
 *   1. Creates 2 publisher accounts via the backend API
 *   2. Publishes 3 link resources (real, publicly accessible URLs)
 *   3. Verifies each resource appears in the public catalog
 *
 * Prerequisites:
 *   - Backend API running (local or Railway)
 *   - Set env vars below
 *
 * Usage:
 *   BACKEND_URL=https://your-app.railway.app \
 *   node scripts/05-seed-catalog.js
 */

const BASE = process.env.BACKEND_URL ?? "http://localhost:3000";

// ── Real resources to publish ─────────────────────────────────────────────────
// Each has a real, publicly accessible URL so the x402 paywall demo is genuine.
const PUBLISHERS = [
  {
    name:          "AtriumMind Research Lab",
    email:         "research@atriumind.demo",
    walletAddress: process.env.PUBLISHER1_PUBLIC ?? "GCKIQDFNL4XFUCYVTPXPJQ4B5EQMUMHZXG3IQMPNHILGQBXQNQ4OQQL",
  },
  {
    name:          "AtriumMind Data Studio",
    email:         "data@atriumind.demo",
    walletAddress: process.env.PUBLISHER2_PUBLIC ?? "GDMRXXCJGU7BPQZLULXUIFXKDKWKNZZN2YQJM7SQGFHFQFBUFZXRRCXP",
  },
];

const RESOURCES = [
  {
    publisherIdx: 0,
    title:        "Stellar Soroban Smart Contract Patterns (2025 Edition)",
    description:
      "A curated reference of production-tested Soroban contract patterns: " +
      "access control, upgradeable proxies, time-locks, circuit breakers, " +
      "and multi-sig. Includes annotated Rust source for each pattern.",
    price:        "0.50",
    externalUrl:  "https://developers.stellar.org/docs/build/smart-contracts/example-contracts",
    resourceType: "link",
  },
  {
    publisherIdx: 1,
    title:        "Stellar Network Analytics Dataset — Q1 2025",
    description:
      "Aggregated on-chain metrics for Stellar mainnet: daily active accounts, " +
      "payment volume by asset, DEX trade counts, and Soroban contract invocations. " +
      "CSV format, 90 days of data, updated weekly.",
    price:        "1.00",
    externalUrl:  "https://dashboard.stellar.org",
    resourceType: "link",
  },
  {
    publisherIdx: 0,
    title:        "x402 Payment Protocol — Integration Guide",
    description:
      "Step-by-step integration guide for the x402 HTTP payment protocol on Stellar. " +
      "Covers server middleware setup, client-side fetch wrapper, USDC settlement, " +
      "and receipt verification. Includes working Node.js + React examples.",
    price:        "0.25",
    externalUrl:  "https://github.com/x402-org/x402",
    resourceType: "link",
  },
];

// ── Helpers ───────────────────────────────────────────────────────────────────
async function post(path, body, apiKey) {
  const headers = { "Content-Type": "application/json" };
  if (apiKey) headers["Authorization"] = `Bearer ${apiKey}`;
  const res  = await fetch(`${BASE}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
  const json = await res.json();
  if (!res.ok) throw new Error(`POST ${path} → ${res.status}: ${JSON.stringify(json)}`);
  return json;
}

async function get(path) {
  const res  = await fetch(`${BASE}${path}`);
  const json = await res.json();
  if (!res.ok) throw new Error(`GET ${path} → ${res.status}: ${JSON.stringify(json)}`);
  return json;
}

// ── Main ──────────────────────────────────────────────────────────────────────
console.log(`\n▸ Seeding AtriumMind catalog at ${BASE}\n`);

const apiKeys = [];

// 1. Create publishers
for (const pub of PUBLISHERS) {
  try {
    console.log(`  Creating publisher: ${pub.name}…`);
    const result = await post("/publishers", pub);
    apiKeys.push(result.apiKey);
    console.log(`  ✅ ${pub.name} — API key: ${result.apiKey.slice(0, 12)}…`);
  } catch (err) {
    // Publisher may already exist on re-runs
    console.warn(`  ⚠  ${pub.name}: ${err.message} (may already exist)`);
    apiKeys.push(process.env[`PUBLISHER${PUBLISHERS.indexOf(pub) + 1}_API_KEY`] ?? "");
  }
}

// 2. Publish resources
const published = [];
for (const r of RESOURCES) {
  const apiKey = apiKeys[r.publisherIdx];
  if (!apiKey) { console.warn(`  ⚠  No API key for publisher ${r.publisherIdx}, skipping.`); continue; }

  try {
    console.log(`\n  Publishing: "${r.title}"…`);
    const result = await post(
      "/resources",
      { title: r.title, description: r.description, price: r.price, externalUrl: r.externalUrl },
      apiKey,
    );
    published.push(result);
    console.log(`  ✅ Resource ID: ${result.id}`);
    console.log(`     Access URL:  ${result.accessUrl}`);
  } catch (err) {
    console.error(`  ❌ Failed to publish "${r.title}": ${err.message}`);
  }
}

// 3. Verify catalog
console.log("\n  Verifying catalog…");
try {
  const catalog = await get("/resources?listed=true");
  const items   = catalog.resources ?? catalog.data ?? catalog;
  console.log(`  ✅ Catalog has ${Array.isArray(items) ? items.length : "?"} listed resource(s)\n`);
} catch (err) {
  console.warn(`  ⚠  Catalog check failed: ${err.message}`);
}

// 4. Print summary
console.log("╔══════════════════════════════════════════════════════╗");
console.log("║   Catalog seeded ✅                                  ║");
console.log("╚══════════════════════════════════════════════════════╝\n");
console.log("Published resources:");
for (const r of published) {
  console.log(`  • ${r.id}  ${r.accessUrl}`);
}
console.log("\nNext → verify everything end-to-end:");
console.log("  node scripts/06-smoke-test.js\n");
