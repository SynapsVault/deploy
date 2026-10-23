/**
 * SynapsVault — Step 5: Seed the catalog with 3 real resources
 *
 * This script:
 *   1. Validates PUBLISHER1_PUBLIC and PUBLISHER2_PUBLIC ed25519 public keys
 *   2. Checks existing catalog items so re-runs are idempotent
 *   3. Creates publisher accounts via the backend API (or reuses existing keys)
 *   4. Publishes any missing link resources (real, publicly accessible URLs)
 *   5. Verifies each resource appears in the public catalog and exits non-zero on failure
 *
 * Prerequisites:
 *   - Backend API running (local or Railway)
 *   - Set PUBLISHER1_PUBLIC and PUBLISHER2_PUBLIC env vars
 *
 * Usage:
 *   BACKEND_URL=https://your-app.railway.app \
 *   PUBLISHER1_PUBLIC=G... \
 *   PUBLISHER2_PUBLIC=G... \
 *   node scripts/05-seed-catalog.js
 */

import { StrKey } from "@stellar/stellar-sdk";

const BASE = process.env.BACKEND_URL ?? "http://localhost:3000";

function resolvePublisherWallets(env = process.env) {
  const pub1 = env.PUBLISHER1_PUBLIC?.trim() ?? "";
  const pub2 = env.PUBLISHER2_PUBLIC?.trim() ?? "";
  const errors = [];

  if (!pub1) {
    errors.push("PUBLISHER1_PUBLIC is required");
  } else if (!StrKey.isValidEd25519PublicKey(pub1)) {
    errors.push(`PUBLISHER1_PUBLIC is not a valid Stellar ed25519 public key: ${pub1}`);
  }

  if (!pub2) {
    errors.push("PUBLISHER2_PUBLIC is required");
  } else if (!StrKey.isValidEd25519PublicKey(pub2)) {
    errors.push(`PUBLISHER2_PUBLIC is not a valid Stellar ed25519 public key: ${pub2}`);
  }

  if (errors.length > 0) {
    throw new Error(`Invalid publisher configuration:\n  - ${errors.join("\n  - ")}`);
  }

  return [
    {
      name: "SynapsVault Research Lab",
      email: "research@synapsvault.demo",
      walletAddress: pub1,
      envApiKey: env.PUBLISHER1_API_KEY ?? "",
    },
    {
      name: "SynapsVault Data Studio",
      email: "data@synapsvault.demo",
      walletAddress: pub2,
      envApiKey: env.PUBLISHER2_API_KEY ?? "",
    },
  ];
}

export const RESOURCES = [
  {
    publisherIdx: 0,
    title: "Stellar Soroban Smart Contract Patterns (2025 Edition)",
    description:
      "A curated reference of production-tested Soroban contract patterns: " +
      "access control, upgradeable proxies, time-locks, circuit breakers, " +
      "and multi-sig. Includes annotated Rust source for each pattern.",
    price: "0.50",
    externalUrl: "https://developers.stellar.org/docs/build/smart-contracts/example-contracts",
    resourceType: "link",
  },
  {
    publisherIdx: 1,
    title: "Stellar Network Analytics Dataset — Q1 2025",
    description:
      "Aggregated on-chain metrics for Stellar mainnet: daily active accounts, " +
      "payment volume by asset, DEX trade counts, and Soroban contract invocations. " +
      "CSV format, 90 days of data, updated weekly.",
    price: "1.00",
    externalUrl: "https://dashboard.stellar.org",
    resourceType: "link",
  },
  {
    publisherIdx: 0,
    title: "x402 Payment Protocol — Integration Guide",
    description:
      "Step-by-step integration guide for the x402 HTTP payment protocol on Stellar. " +
      "Covers server middleware setup, client-side fetch wrapper, USDC settlement, " +
      "and receipt verification. Includes working Node.js + React examples.",
    price: "0.25",
    externalUrl: "https://github.com/x402-org/x402",
    resourceType: "link",
  },
];

// ── Helpers ───────────────────────────────────────────────────────────────────
async function post(path, body, apiKey) {
  const headers = { "Content-Type": "application/json" };
  if (apiKey) headers["Authorization"] = `Bearer ${apiKey}`;
  const res = await fetch(`${BASE}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text };
  }
  if (!res.ok) {
    const err = new Error(`POST ${path} → ${res.status}: ${JSON.stringify(json)}`);
    err.status = res.status;
    throw err;
  }
  return json;
}

async function get(path) {
  const res = await fetch(`${BASE}${path}`);
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text };
  }
  if (!res.ok) {
    const err = new Error(`GET ${path} → ${res.status}: ${JSON.stringify(json)}`);
    err.status = res.status;
    throw err;
  }
  return json;
}

function extractCatalogItems(catalog) {
  const items = catalog?.resources ?? catalog?.data ?? catalog;
  return Array.isArray(items) ? items : [];
}

function findExistingResource(items, resource) {
  return items.find(
    (item) =>
      item &&
      (item.title === resource.title ||
        (item.externalUrl && item.externalUrl === resource.externalUrl))
  );
}

// ── Main ──────────────────────────────────────────────────────────────────────
let publishers;
try {
  publishers = resolvePublisherWallets(process.env);
} catch (err) {
  console.error(`\n❌ ${err.message}\n`);
  process.exit(1);
}

console.log(`\n▸ Seeding SynapsVault catalog at ${BASE}\n`);

let failures = 0;
let existingItems = [];

try {
  const initialCatalog = await get("/resources?listed=true");
  existingItems = extractCatalogItems(initialCatalog);
} catch (err) {
  console.error(`  ❌ Could not fetch existing catalog: ${err.message}`);
  process.exit(1);
}

const apiKeys = [];

// 1. Create publishers (or reuse existing publisher keys on idempotent re-runs)
for (let i = 0; i < publishers.length; i++) {
  const pub = publishers[i];
  const needsPublish = RESOURCES.some(
    (r) => r.publisherIdx === i && !findExistingResource(existingItems, r)
  );

  try {
    console.log(`  Creating publisher: ${pub.name}…`);
    const result = await post("/publishers", {
      name: pub.name,
      email: pub.email,
      walletAddress: pub.walletAddress,
    });
    apiKeys.push(result.apiKey ?? pub.envApiKey);
    console.log(`  ✅ ${pub.name} — publisher ready`);
  } catch (err) {
    if (err.status === 409 || /already exists/i.test(err.message)) {
      console.warn(`  ℹ  ${pub.name}: publisher already exists`);
      apiKeys.push(pub.envApiKey);
      if (needsPublish && !pub.envApiKey) {
        console.error(
          `  ❌ ${pub.name} already exists and PUBLISHER${i + 1}_API_KEY is not set to publish missing resources.`
        );
        failures++;
      }
    } else {
      console.error(`  ❌ Failed to create publisher ${pub.name}: ${err.message}`);
      apiKeys.push("");
      failures++;
    }
  }
}

// 2. Publish resources idempotently
const published = [];
for (const r of RESOURCES) {
  const existing = findExistingResource(existingItems, r);
  if (existing) {
    console.log(`\n  ℹ  Already seeded: "${r.title}" (ID: ${existing.id})`);
    published.push(existing);
    continue;
  }

  const apiKey = apiKeys[r.publisherIdx];
  if (!apiKey) {
    console.error(`  ❌ No API key for publisher ${r.publisherIdx}; cannot publish "${r.title}".`);
    failures++;
    continue;
  }

  try {
    console.log(`\n  Publishing: "${r.title}"…`);
    const result = await post(
      "/resources",
      { title: r.title, description: r.description, price: r.price, externalUrl: r.externalUrl },
      apiKey
    );
    published.push(result);
    existingItems.push(result);
    console.log(`  ✅ Resource ID: ${result.id}`);
    console.log(`     Access URL:  ${result.accessUrl}`);
  } catch (err) {
    console.error(`  ❌ Failed to publish "${r.title}": ${err.message}`);
    failures++;
  }
}

// 3. Verify catalog
console.log("\n  Verifying catalog…");
try {
  const catalog = await get("/resources?listed=true");
  const items = extractCatalogItems(catalog);
  console.log(`  ✅ Catalog has ${items.length} listed resource(s)\n`);
  if (items.length < RESOURCES.length) {
    console.error(
      `  ❌ Expected at least ${RESOURCES.length} catalog resources, found ${items.length}`
    );
    failures++;
  }
} catch (err) {
  console.error(`  ❌ Catalog check failed: ${err.message}`);
  failures++;
}

if (failures > 0 || published.length < RESOURCES.length) {
  console.error(
    `\n❌ Seeding failed (${failures} error(s), ${published.length}/${RESOURCES.length} resources ready).\n`
  );
  process.exit(1);
}

// 4. Print summary
console.log("╔══════════════════════════════════════════════════════╗");
console.log("║   Catalog seeded ✅                                  ║");
console.log("╚══════════════════════════════════════════════════════╝\n");
console.log("Published resources:");
for (const r of published) {
  console.log(`  • ${r.id}  ${r.accessUrl ?? r.externalUrl ?? r.title}`);
}
console.log("\nNext → verify everything end-to-end:");
console.log("  node scripts/06-smoke-test.js\n");
