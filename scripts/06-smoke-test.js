/**
 * SynapsVault — Step 6: End-to-end smoke test
 *
 * Checks every critical path before submitting to SCF:
 *   ✓ Backend health
 *   ✓ Registry on-chain count
 *   ✓ Catalog returns resources (captures a real resource ID)
 *   ✓ x402 paywall returns 402 on unauthenticated access to a real resource
 *   ✓ Admin stats endpoint rejects unauthenticated requests and succeeds with valid key
 *   ✓ OpenAPI docs served
 *
 * Usage:
 *   BACKEND_URL=https://your-app.railway.app \
 *   ADMIN_API_KEY=your_admin_key \
 *   node scripts/06-smoke-test.js
 *
 * The base URL may be passed as the first CLI argument (e.g. from CI):
 *   node scripts/06-smoke-test.js "$DEPLOY_URL/api"
 */

const BASE = process.argv[2] ?? process.env.BACKEND_URL ?? "http://localhost:3000";
const ADMIN_KEY = process.env.ADMIN_API_KEY ?? "change_me";

// When run against a freshly started docker-compose stack, services may still
// be warming up even after `docker compose up -d --wait`. Allow a bounded
// retry window so CI smoke tests are not flaky on cold starts.
const READY_TIMEOUT_MS = Number(process.env.SMOKE_READY_TIMEOUT_MS ?? 60000);
const READY_INTERVAL_MS = 2000;

let passed = 0;
let failed = 0;

async function check(label, fn) {
  try {
    const result = await fn();
    console.log(`  ✅ ${label}${result ? `  →  ${result}` : ""}`);
    passed++;
  } catch (err) {
    console.error(`  ❌ ${label}  →  ${err.message}`);
    failed++;
  }
}

async function get(path, headers = {}) {
  const res = await fetch(`${BASE}${path}`, { headers });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

async function waitForBackend() {
  const deadline = Date.now() + READY_TIMEOUT_MS;
  let lastErr;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${BASE}/health`);
      if (res.ok) return;
      lastErr = new Error(`HTTP ${res.status}`);
    } catch (err) {
      lastErr = err;
    }
    await new Promise((r) => setTimeout(r, READY_INTERVAL_MS));
  }
  throw new Error(
    `Backend not ready at ${BASE}/health within ${READY_TIMEOUT_MS}ms` +
      (lastErr ? ` (last error: ${lastErr.message})` : "")
  );
}

console.log(`\n▸ SynapsVault smoke test — ${BASE}\n`);

// Wait for the stack to accept traffic before running checks.
try {
  await waitForBackend();
} catch (err) {
  console.error(`  ❌ ${err.message}`);
  process.exit(1);
}

// Health
await check("Backend health", async () => {
  const d = await get("/health");
  return d.status ?? "ok";
});

// Registry
await check("On-chain registry reachable", async () => {
  const d = await get("/registry/status");
  return `${d.resourceCount ?? 0} resources registered`;
});

// Catalog — capture a real resource ID for the paywall check
let sampleResourceId = null;
await check("Catalog returns resources", async () => {
  const d = await get("/resources");
  const items = d.resources ?? d.data ?? d;
  if (!Array.isArray(items) || items.length === 0) {
    throw new Error("Expected at least 1 resource in catalog, got 0");
  }
  sampleResourceId = items[0]?.id ?? null;
  if (!sampleResourceId) {
    throw new Error("First catalog resource is missing an id field");
  }
  return `${items.length} item(s) (sample id=${sampleResourceId})`;
});

// Paywall — expect 402 against a real catalog resource ID
await check("x402 paywall blocks unauthenticated access", async () => {
  if (!sampleResourceId) {
    throw new Error("Cannot test paywall: no real resource ID available from catalog");
  }
  const res = await fetch(`${BASE}/resources/${encodeURIComponent(sampleResourceId)}`, {
    redirect: "manual",
  });
  if (res.status !== 402)
    throw new Error(`Expected 402 for resource ${sampleResourceId}, got ${res.status}`);
  return `resource ${sampleResourceId} returns 402 as expected`;
});

// Admin stats — verify unauthenticated access is rejected AND authenticated access works
await check("Admin stats endpoint protected", async () => {
  const unauthRes = await fetch(`${BASE}/admin/stats`);
  if (unauthRes.status !== 401 && unauthRes.status !== 403) {
    throw new Error(`Expected 401/403 without X-Admin-Key, got ${unauthRes.status}`);
  }

  const badKeyRes = await fetch(`${BASE}/admin/stats`, {
    headers: { "X-Admin-Key": `${ADMIN_KEY}-invalid` },
  });
  if (badKeyRes.status !== 401 && badKeyRes.status !== 403) {
    throw new Error(`Expected 401/403 with invalid X-Admin-Key, got ${badKeyRes.status}`);
  }

  const res = await fetch(`${BASE}/admin/stats`, {
    headers: { "X-Admin-Key": ADMIN_KEY },
  });
  if (!res.ok) throw new Error(`Authenticated request failed with HTTP ${res.status}`);
  const d = await res.json();
  return `unauth=${unauthRes.status}, auth=200 (resources=${d.resources}, publishers=${d.publishers})`;
});

// OpenAPI docs
await check("OpenAPI docs served", async () => {
  const res = await fetch(`${BASE}/docs`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return "Swagger UI reachable";
});

// Summary
console.log(`\n${"─".repeat(50)}`);
console.log(`  ${passed} passed  /  ${failed} failed`);
if (failed === 0) {
  console.log("\n  🎉 All checks passed — ready for SCF submission!\n");
} else {
  console.log("\n  ⚠  Fix the failures above before submitting.\n");
  process.exit(1);
}
