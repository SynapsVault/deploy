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
 *
 * Optional flags:
 *   --frontend-url <url>   Fetch <url>/config.js and verify the frontend is
 *                          configured for the expected network and API base.
 *   --report <path>        Write a machine-readable JSON report of all checks
 *                          (name, duration, result, sanitized error).
 *
 * Environment:
 *   EXPECTED_NETWORK       Expected Stellar network for registry/frontend
 *                          checks (default: "testnet").
 *   EXPECTED_CONTRACT_ID   Expected registry contract ID (optional).
 *   EXPECTED_API_BASE      Expected API base URL in the frontend config
 *                          (default: the smoke-test BASE URL).
 */

function parseArgs(argv) {
  const opts = { base: null, frontendUrl: null, reportPath: null };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--frontend-url") {
      opts.frontendUrl = argv[++i] ?? null;
    } else if (arg.startsWith("--frontend-url=")) {
      opts.frontendUrl = arg.slice("--frontend-url=".length);
    } else if (arg === "--report") {
      opts.reportPath = argv[++i] ?? null;
    } else if (arg.startsWith("--report=")) {
      opts.reportPath = arg.slice("--report=".length);
    } else {
      rest.push(arg);
    }
  }
  opts.base = rest[0] ?? null;
  return opts;
}

const OPTS = parseArgs(process.argv.slice(2));
const EXPECTED_NETWORK = (process.env.EXPECTED_NETWORK ?? "testnet").toLowerCase();
const EXPECTED_CONTRACT_ID = process.env.EXPECTED_CONTRACT_ID ?? null;
// ── Configuration validation (runs before any network calls) ────────────────

function configError(message) {
  console.error(`\n  ❌ Configuration error: ${message}\n`);
  process.exit(1);
}

// Base URL — parse and normalize so a trailing slash never produces `//`.
const RAW_BASE = OPTS.base ?? process.env.BACKEND_URL ?? "http://localhost:3000";
let BASE;
try {
  const parsed = new URL(RAW_BASE);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    configError(`BACKEND_URL must use http or https, got "${parsed.protocol}"`);
  }
  // Strip trailing slashes from the pathname while preserving any prefix (e.g. /api).
  parsed.pathname = parsed.pathname.replace(/\/+$/, "");
  parsed.search = "";
  parsed.hash = "";
  BASE = parsed.toString().replace(/\/+$/, "");
} catch (err) {
  configError(`Invalid BACKEND_URL "${RAW_BASE}": ${err.message}`);
}

const EXPECTED_API_BASE = process.env.EXPECTED_API_BASE ?? BASE;

// Admin API key — must be explicitly provided and must not be a placeholder.
const PLACEHOLDER_KEYS = new Set([
  "change_me",
  "change-me",
  "change-me-to-a-long-random-string",
  "changeme",
  "your_admin_key",
  "admin",
  "test",
]);
const ADMIN_KEY = process.env.ADMIN_API_KEY;
if (!ADMIN_KEY || ADMIN_KEY.trim() === "") {
  configError("ADMIN_API_KEY is not set. Provide a real admin key via the environment.");
}
if (PLACEHOLDER_KEYS.has(ADMIN_KEY.trim().toLowerCase())) {
  configError(
    "ADMIN_API_KEY is set to a placeholder value. Provide a real admin key via the environment."
  );
}

// Readiness timeout — must be a finite, strictly positive number of milliseconds.
const RAW_TIMEOUT = process.env.SMOKE_READY_TIMEOUT_MS ?? "60000";
const READY_TIMEOUT_MS = Number(RAW_TIMEOUT);
if (!Number.isFinite(READY_TIMEOUT_MS)) {
  configError(`SMOKE_READY_TIMEOUT_MS must be a finite number, got "${RAW_TIMEOUT}"`);
}
if (READY_TIMEOUT_MS <= 0) {
  configError(`SMOKE_READY_TIMEOUT_MS must be greater than zero, got "${RAW_TIMEOUT}"`);
}
const READY_INTERVAL_MS = 2000;

// Per-request deadline. A server that accepts connections but never responds
// must not hang the smoke test, so every fetch is bounded by this timeout.
const REQUEST_TIMEOUT_MS = Number(process.env.SMOKE_REQUEST_TIMEOUT_MS ?? 10000);

/**
 * fetch() wrapper that aborts after REQUEST_TIMEOUT_MS. Timeouts are surfaced
 * as a clear error so callers (and the summary) report a bounded failure.
 */
async function fetchWithTimeout(url, options = {}) {
  try {
    return await fetch(url, {
      ...options,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (err) {
    if (err?.name === "TimeoutError" || err?.name === "AbortError") {
      throw new Error(`Request to ${url} timed out after ${REQUEST_TIMEOUT_MS}ms`);
    }
    throw err;
  }
}
// Join a normalized base URL with an endpoint path using exactly one slash.
function url(path) {
  return `${BASE}/${String(path).replace(/^\/+/, "")}`;
}

let passed = 0;
let failed = 0;
const reportEntries = [];

// Strip anything that could leak credentials (admin keys, tokens, secrets)
// from error messages before they are printed or written to the report.
function sanitize(message) {
  let out = String(message ?? "");
  const secrets = [ADMIN_KEY, process.env.ADMIN_API_KEY].filter(
    (s) => typeof s === "string" && s.length > 0
  );
  for (const secret of secrets) {
    out = out.split(secret).join("[REDACTED]");
  }
  out = out.replace(/(X-Admin-Key["']?\s*[:=]\s*["']?)[^"'\s,}]+/gi, "$1[REDACTED]");
  out = out.replace(/((?:api[_-]?key|token|secret|password)["']?\s*[:=]\s*["']?)[^"'\s,}]+/gi, "$1[REDACTED]");
  return out;
}

async function check(label, fn) {
  const startedAt = Date.now();
  try {
    const result = await fn();
    const durationMs = Date.now() - startedAt;
    console.log(`  ✅ ${label}${result ? `  →  ${result}` : ""}`);
    passed++;
    reportEntries.push({ name: label, durationMs, status: "passed", result: result ?? null, error: null });
  } catch (err) {
    const durationMs = Date.now() - startedAt;
    const message = sanitize(err?.message ?? err);
    console.error(`  ❌ ${label}  →  ${message}`);
    failed++;
    reportEntries.push({ name: label, durationMs, status: "failed", result: null, error: message });
  }
}

async function get(path, headers = {}) {
  const res = await fetchWithTimeout(url(path), { headers });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

async function getJson(path, headers = {}) {
  const res = await fetchWithTimeout(`${BASE}${path}`, { headers });
  const text = await res.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    throw new Error(`HTTP ${res.status} — response is not valid JSON`);
  }
  return { res, body };
}

async function waitForBackend() {
  const deadline = Date.now() + READY_TIMEOUT_MS;
  let lastErr;
  while (Date.now() < deadline) {
    try {
      const res = await fetchWithTimeout(url("/health"));
      if (res.ok) return;
      lastErr = new Error(`HTTP ${res.status}`);
    } catch (err) {
      lastErr = err;
    }
    await new Promise((r) => setTimeout(r, READY_INTERVAL_MS));
  }
  throw new Error(
    `Backend not ready at ${url("/health")} within ${READY_TIMEOUT_MS}ms` +
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

// Health — require HTTP 200 plus the documented healthy state.
await check("Backend health", async () => {
  const { res, body } = await getJson("/health");
  if (res.status !== 200) {
    throw new Error(`Expected HTTP 200 from /health, got ${res.status}`);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("Malformed /health payload: expected a JSON object");
  }
  if (!("status" in body)) {
    throw new Error("Malformed /health payload: missing 'status' field");
  }
  const status = String(body.status).toLowerCase();
  if (status !== "ok" && status !== "healthy") {
    throw new Error(`Health status is '${body.status}' (expected 'ok'/'healthy') — service is degraded`);
  }
  return `status=${body.status}`;
});

// Registry — validate payload shape, counts, and contract/network identity.
await check("On-chain registry reachable", async () => {
  const { res, body: d } = await getJson("/registry/status");
  if (res.status !== 200) {
    throw new Error(`Expected HTTP 200 from /registry/status, got ${res.status}`);
  }
  if (!d || typeof d !== "object" || Array.isArray(d)) {
    throw new Error("Malformed /registry/status payload: expected a JSON object");
  }

  const count = d.resourceCount ?? d.count;
  if (count === undefined || count === null) {
    throw new Error("Malformed /registry/status payload: missing resourceCount");
  }
  if (typeof count !== "number" || !Number.isInteger(count) || count < 0) {
    throw new Error(`Malformed resourceCount: expected a non-negative integer, got ${JSON.stringify(count)}`);
  }

  const network = d.network ?? d.networkPassphrase ?? d.network_passphrase;
  if (network !== undefined && network !== null) {
    const actual = String(network).toLowerCase();
    if (!actual.includes(EXPECTED_NETWORK)) {
      throw new Error(
        `Registry network mismatch: expected '${EXPECTED_NETWORK}', got '${network}'`
      );
    }
  }

  const contractId = d.contractId ?? d.contract_id ?? d.contract;
  if (contractId !== undefined && contractId !== null) {
    if (typeof contractId !== "string" || !/^C[A-Z2-7]{55}$/.test(contractId)) {
      throw new Error(`Malformed contractId in /registry/status: ${JSON.stringify(contractId)}`);
    }
    if (EXPECTED_CONTRACT_ID && contractId !== EXPECTED_CONTRACT_ID) {
      throw new Error(
        `Registry contract mismatch: expected '${EXPECTED_CONTRACT_ID}', got '${contractId}'`
      );
    }
  } else if (EXPECTED_CONTRACT_ID) {
    throw new Error("Registry status does not expose a contractId to verify against EXPECTED_CONTRACT_ID");
  }

  const identity = contractId ? `, contract=${contractId}` : "";
  return `${count} resources registered${identity}`;
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
  const res = await fetchWithTimeout(url(`/resources/${encodeURIComponent(sampleResourceId)}`), {
    redirect: "manual",
  });
  if (res.status !== 402)
    throw new Error(`Expected 402 for resource ${sampleResourceId}, got ${res.status}`);
  return `resource ${sampleResourceId} returns 402 as expected`;
});

// Admin stats — verify unauthenticated access is rejected AND authenticated access works
await check("Admin stats endpoint protected", async () => {
  const unauthRes = await fetchWithTimeout(url("/admin/stats"), { redirect: "manual" });
  if (unauthRes.status !== 401 && unauthRes.status !== 403) {
    throw new Error(`Expected 401/403 without X-Admin-Key, got ${unauthRes.status}`);
  }
  const badKeyRes = await fetchWithTimeout(url("/admin/stats"), {
    headers: { "X-Admin-Key": `${ADMIN_KEY}-invalid` },
    redirect: "manual",
  });
  if (badKeyRes.status !== 401 && badKeyRes.status !== 403) {
    throw new Error(`Expected 401/403 with invalid X-Admin-Key, got ${badKeyRes.status}`);
  }
  // Authenticated request: never follow redirects automatically. If the server
  // redirects cross-origin, fail without re-sending X-Admin-Key to that origin.
  const res = await fetchWithTimeout(url("/admin/stats"), {
    headers: { "X-Admin-Key": ADMIN_KEY },
    redirect: "manual",
  });
  if (res.status >= 300 && res.status < 400) {
    const location = res.headers.get("location");
    if (!location) {
      throw new Error(`Authenticated request redirected (HTTP ${res.status}) without a Location header`);
    }
    let target;
    try {
      target = new URL(location, url("/admin/stats"));
    } catch (err) {
      throw new Error(`Authenticated request redirected to an invalid Location "${location}"`);
    }
    if (target.origin !== new URL(BASE).origin) {
      throw new Error(
        `Authenticated request redirected cross-origin to ${target.origin}; refusing to forward X-Admin-Key`
      );
    }
    throw new Error(`Authenticated request redirected (HTTP ${res.status}) to ${target.pathname}`);
  }
  if (!res.ok) throw new Error(`Authenticated request failed with HTTP ${res.status}`);
  const d = await res.json();
  return `unauth=${unauthRes.status}, auth=200 (resources=${d.resources}, publishers=${d.publishers})`;
});

// OpenAPI docs — verify the actual OpenAPI document, not just any 200 response.
// An ingress SPA fallback can return HTML with status 200 for /docs, so we
// fetch the JSON spec and assert its content signature.
const OPENAPI_PATHS = ["/docs/json", "/openapi.json", "/docs-json"];
await check("OpenAPI docs served", async () => {
  const attempts = [];
  for (const path of OPENAPI_PATHS) {
    const res = await fetchWithTimeout(`${BASE}${path}`, {
      headers: { Accept: "application/json" },
    });
    const contentType = res.headers.get("content-type") ?? "(none)";
    const body = await res.text();
    const snippet = body.slice(0, 120).replace(/\s+/g, " ").trim();

    if (!res.ok) {
      attempts.push(`${path}: HTTP ${res.status} [${contentType}] ${snippet}`);
      continue;
    }

    if (/text\/html|application\/xhtml/i.test(contentType) || /^\s*</.test(body)) {
      attempts.push(
        `${path}: HTML response (SPA fallback?) [${contentType}] ${snippet}`
      );
      continue;
    }

    let doc;
    try {
      doc = JSON.parse(body);
    } catch {
      attempts.push(`${path}: not valid JSON [${contentType}] ${snippet}`);
      continue;
    }

    const hasVersion = typeof doc?.openapi === "string" || typeof doc?.swagger === "string";
    const hasInfo = doc?.info && typeof doc.info === "object";
    if (!hasVersion || !hasInfo) {
      attempts.push(
        `${path}: missing OpenAPI signature (openapi/swagger + info) [${contentType}] ${snippet}`
      );
      continue;
    }

    const version = doc.openapi ?? doc.swagger;
    return `${path} → OpenAPI ${version} (${doc.info.title ?? "untitled"})`;
  }

  throw new Error(`No valid OpenAPI document found:\n    ${attempts.join("\n    ")}`);
});

// Frontend runtime config — optional, verifies the deployed frontend points at
// the expected network and API base (detects wrong-environment deployments).
if (OPTS.frontendUrl) {
  await check("Frontend runtime config matches deployment", async () => {
    const configUrl = `${OPTS.frontendUrl.replace(/\/+$/, "")}/config.js`;
    const res = await fetchWithTimeout(configUrl);
    if (!res.ok) throw new Error(`HTTP ${res.status} fetching ${configUrl}`);
    const text = await res.text();

    const readValue = (key) => {
      const re = new RegExp(`${key}\\s*[:=]\\s*["']([^"']*)["']`);
      const m = text.match(re);
      return m ? m[1] : null;
    };

    const network = readValue("network") ?? readValue("NETWORK");
    if (!network) {
      throw new Error("Frontend config.js does not expose a network value");
    }
    if (!network.toLowerCase().includes(EXPECTED_NETWORK)) {
      throw new Error(
        `Frontend network mismatch: expected '${EXPECTED_NETWORK}', got '${network}'`
      );
    }

    const apiBase = readValue("apiBase") ?? readValue("API_BASE") ?? readValue("apiUrl");
    if (!apiBase) {
      throw new Error("Frontend config.js does not expose an API base URL");
    }
    const normalize = (u) => u.replace(/\/+$/, "");
    if (normalize(apiBase) !== normalize(EXPECTED_API_BASE)) {
      throw new Error(
        `Frontend API base mismatch: expected '${EXPECTED_API_BASE}', got '${apiBase}'`
      );
    }

    return `network=${network}, apiBase=${apiBase}`;
  });
}

// Summary
console.log(`\n${"─".repeat(50)}`);
console.log(`  ${passed} passed  /  ${failed} failed`);

// Optional machine-readable report.
if (OPTS.reportPath) {
  const { writeFileSync } = await import("node:fs");
  const report = {
    baseUrl: BASE,
    frontendUrl: OPTS.frontendUrl ?? null,
    expectedNetwork: EXPECTED_NETWORK,
    timestamp: new Date().toISOString(),
    passed,
    failed,
    checks: reportEntries,
  };
  try {
    writeFileSync(OPTS.reportPath, JSON.stringify(report, null, 2));
    console.log(`  📄 Report written to ${OPTS.reportPath}`);
  } catch (err) {
    console.error(`  ⚠  Failed to write report: ${sanitize(err.message)}`);
    failed++;
  }
}

if (failed === 0) {
  console.log("\n  🎉 All checks passed — ready for SCF submission!\n");
} else {
  console.log("\n  ⚠  Fix the failures above before submitting.\n");
  process.exit(1);
}
