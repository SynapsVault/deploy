#!/usr/bin/env node
/**
 * scripts/check-env.js
 *
 * Validates that all required environment variables for a given deployment
 * target are present and have been filled in (no placeholder values).
 *
 * Usage:
 *   node scripts/check-env.js [--target <compose|k8s|railway>] [--env-file <path>]
 *
 * Options:
 *   --target   Deployment target to validate (default: compose)
 *              compose  — local Docker Compose stack
 *              k8s      — Kubernetes / Kustomize deploy
 *              railway  — Railway backend deploy
 *   --env-file Path to the .env file to check (default: .env)
 *   --help     Print this help message
 *
 * Exit codes:
 *   0  All required variables are set and have non-placeholder values
 *   1  One or more variables are missing or contain placeholder values
 *
 * Placeholder patterns detected:
 *   - Keys that match S[XXX...] (Stellar secret key template)
 *   - Keys that match C[XXX...] (Contract ID template)
 *   - Keys that match G[XXX...] (Stellar public key template)
 *   - Values starting with REPLACE_ME
 *   - Values starting with change-me
 *   - Values starting with your-
 *   - Values equal to a well-known .env.example default that must be replaced
 *     (e.g. "your-supabase-anon-key", "your-openrouter-api-key")
 *
 * This script only reads from the specified --env-file and the current process
 * environment (process.env). It never mutates either.
 */

import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

// ---------------------------------------------------------------------------
// Placeholder detection
// ---------------------------------------------------------------------------

/**
 * Patterns whose presence in a value (case-insensitive prefix/substring match)
 * indicates the value has not been filled in.
 *
 * @type {Array<RegExp>}
 */
const PLACEHOLDER_PATTERNS = [
  /^REPLACE_ME/i,
  /^change[-_]me/i,
  /^your-/i,
  // Stellar secret key placeholder: S followed by 55 uppercase Xs (or just many Xs)
  /^S[X]{10,}/,
  // Contract/account ID placeholder: C or G followed by 55 uppercase Xs
  /^[CG][X]{10,}/,
  // Literal placeholder text embedded in docs
  /^\[YOUR-/i,
  /^<your-/i,
  /^\[FILL/i,
  /^←\s*FILL/i,
  /^\[from /i,
  /^eyJ\.{3}/, // truncated JWT placeholder "eyJ..."
];

/**
 * Returns true if the value looks like a placeholder that was never filled in.
 *
 * @param {string} value
 * @returns {boolean}
 */
function isPlaceholder(value) {
  if (value === '' || value === undefined || value === null) return false; // handled by "missing" check
  return PLACEHOLDER_PATTERNS.some((re) => re.test(value));
}

// ---------------------------------------------------------------------------
// Required variable definitions per target
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} VarSpec
 * @property {string}   name        Environment variable name
 * @property {string}   description Human-readable description (shown in errors)
 * @property {boolean}  [secret]    True if the value is a secret (masked in output)
 */

/** @type {VarSpec[]} */
const COMPOSE_VARS = [
  { name: 'POSTGRES_USER', description: 'PostgreSQL username for the compose stack' },
  {
    name: 'POSTGRES_PASSWORD',
    description: 'PostgreSQL password for the compose stack',
    secret: true,
  },
  { name: 'POSTGRES_DB', description: 'PostgreSQL database name' },
  { name: 'STELLAR_NETWORK', description: 'Stellar network (testnet/mainnet)' },
  { name: 'SOROBAN_RPC_URL', description: 'Soroban RPC endpoint URL' },
  {
    name: 'STELLAR_SECRET_KEY',
    description: 'Stellar secret key for signing transactions',
    secret: true,
  },
  { name: 'STELLAR_PUBLIC_KEY', description: 'Stellar public key matching STELLAR_SECRET_KEY' },
  { name: 'SUPABASE_URL', description: 'Supabase project URL' },
  { name: 'SUPABASE_ANON_KEY', description: 'Supabase anonymous/public key', secret: true },
  {
    name: 'SUPABASE_SERVICE_KEY',
    description: 'Supabase service role key (backend only)',
    secret: true,
  },
  { name: 'ADMIN_API_KEY', description: 'Admin API key for protected endpoints', secret: true },
  { name: 'OPENROUTER_API_KEY', description: 'OpenRouter API key for LLM access', secret: true },
  {
    name: 'AGENT_SECRET_KEY',
    description: 'Stellar secret key for the agent signer',
    secret: true,
  },
  {
    name: 'REGISTRY_SECRET_KEY',
    description: 'Stellar secret key for the registry signer',
    secret: true,
  },
];

/** @type {VarSpec[]} */
const K8S_VARS = [
  ...COMPOSE_VARS,
  { name: 'STELLAR_CONTRACT_VAULT_REGISTRY', description: 'Deployed vault-registry contract ID' },
  { name: 'STELLAR_CONTRACT_ACCESS_LEASE', description: 'Deployed access-lease contract ID' },
  { name: 'STELLAR_CONTRACT_SUBSCRIPTION', description: 'Deployed subscription contract ID' },
  { name: 'USDC_CONTRACT_ID', description: 'USDC token contract ID' },
];

/** @type {VarSpec[]} */
const RAILWAY_VARS = [
  {
    name: 'DATABASE_URL',
    description: 'Supabase/Railway Postgres connection string',
    secret: true,
  },
  { name: 'SUPABASE_URL', description: 'Supabase project URL' },
  { name: 'SUPABASE_SERVICE_KEY', description: 'Supabase service role key', secret: true },
  {
    name: 'SUPABASE_STORAGE_BUCKET',
    description: 'Supabase storage bucket name (should be "resources")',
  },
  { name: 'STELLAR_NETWORK', description: 'Stellar network (testnet/mainnet)' },
  { name: 'SOROBAN_RPC_URL', description: 'Soroban RPC endpoint URL' },
  { name: 'USDC_CONTRACT_ID', description: 'USDC token contract ID' },
  { name: 'PAY_TO', description: 'Backend wallet public key (Stellar G...)' },
  { name: 'AGENT_SECRET_KEY', description: 'Backend wallet secret key', secret: true },
  { name: 'REGISTRY_SECRET_KEY', description: 'Registry wallet secret key', secret: true },
  { name: 'STELLAR_CONTRACT_VAULT_REGISTRY', description: 'Deployed vault-registry contract ID' },
  { name: 'STELLAR_CONTRACT_ACCESS_LEASE', description: 'Deployed access-lease contract ID' },
  { name: 'STELLAR_CONTRACT_SUBSCRIPTION', description: 'Deployed subscription contract ID' },
  { name: 'OPENROUTER_API_KEY', description: 'OpenRouter API key', secret: true },
  { name: 'ADMIN_API_KEY', description: 'Admin API key for protected endpoints', secret: true },
];

/** @type {Record<string, VarSpec[]>} */
const TARGETS = {
  compose: COMPOSE_VARS,
  k8s: K8S_VARS,
  railway: RAILWAY_VARS,
};

// ---------------------------------------------------------------------------
// .env file parser
// ---------------------------------------------------------------------------

/**
 * Parse a .env file into a key→value map. Handles:
 *  - Comments (#)
 *  - Quoted values ("..." or '...')
 *  - KEY=VALUE and KEY= (empty)
 *  - Blank lines
 *
 * @param {string} filePath
 * @returns {Record<string, string>}
 */
export function parseEnvFile(filePath) {
  if (!existsSync(filePath)) return {};
  const content = readFileSync(filePath, 'utf8');
  /** @type {Record<string, string>} */
  const env = {};
  for (const rawLine of content.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eqIdx = line.indexOf('=');
    if (eqIdx === -1) continue;
    const key = line.slice(0, eqIdx).trim();
    let value = line.slice(eqIdx + 1).trim();
    // Strip inline comments (e.g. VALUE=foo  # comment)
    // only if the value is not quoted
    if (!value.startsWith('"') && !value.startsWith("'")) {
      const commentIdx = value.indexOf(' #');
      if (commentIdx !== -1) value = value.slice(0, commentIdx).trim();
    }
    // Strip surrounding quotes
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    env[key] = value;
  }
  return env;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} ValidationResult
 * @property {boolean}  ok
 * @property {string[]} missing     Variables not set at all
 * @property {string[]} placeholder Variables set to a placeholder value
 */

/**
 * Validate a set of variable specs against the merged env (file + process).
 *
 * @param {VarSpec[]}            specs
 * @param {Record<string,string>} fileEnv
 * @returns {ValidationResult}
 */
export function validateEnv(specs, fileEnv) {
  const missing = [];
  const placeholder = [];

  for (const spec of specs) {
    // process.env takes precedence over the file (mirrors how dotenv works in apps)
    const value = process.env[spec.name] ?? fileEnv[spec.name];
    if (value === undefined || value === null || value === '') {
      missing.push(spec.name);
    } else if (isPlaceholder(value)) {
      placeholder.push(spec.name);
    }
  }

  return {
    ok: missing.length === 0 && placeholder.length === 0,
    missing,
    placeholder,
  };
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

/**
 * Parse process.argv into an options object.
 *
 * @param {string[]} argv  process.argv.slice(2)
 * @returns {{ target: string, envFile: string, help: boolean }}
 */
export function parseArgs(argv) {
  let target = 'compose';
  let envFile = '.env';
  let help = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      help = true;
    } else if (arg === '--target' || arg === '-t') {
      target = argv[++i] ?? target;
    } else if (arg === '--env-file') {
      envFile = argv[++i] ?? envFile;
    } else if (arg.startsWith('--target=')) {
      target = arg.split('=')[1];
    } else if (arg.startsWith('--env-file=')) {
      envFile = arg.split('=')[1];
    }
  }

  return { target, envFile, help };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const HELP_TEXT = `
check-env.js — Validate .env variables for a deployment target

Usage:
  node scripts/check-env.js [--target <compose|k8s|railway>] [--env-file <path>]

Options:
  --target   Deployment target (default: compose)
             compose  — local Docker Compose stack
             k8s      — Kubernetes / Kustomize deploy
             railway  — Railway backend deploy
  --env-file Path to .env file (default: .env)
  --help     Print this help message

Exit codes:
  0  All checks passed
  1  One or more variables are missing or contain placeholder values
`.trim();

/**
 * Run the CLI. Exported so it can be stubbed in tests.
 *
 * @param {string[]} argv  Argument array (default: process.argv.slice(2))
 * @param {string}   [cwd] Working directory for resolving --env-file (default: process.cwd())
 * @returns {number} Exit code
 */
export function run(argv = process.argv.slice(2), cwd = process.cwd()) {
  const { target, envFile, help } = parseArgs(argv);

  if (help) {
    console.log(HELP_TEXT);
    return 0;
  }

  const validTargets = Object.keys(TARGETS);
  if (!validTargets.includes(target)) {
    console.error(
      `check-env: unknown target "${target}". Valid targets: ${validTargets.join(', ')}`
    );
    return 1;
  }

  const resolvedEnvFile = resolve(cwd, envFile);
  const fileEnv = parseEnvFile(resolvedEnvFile);
  const specs = TARGETS[target];

  const { ok, missing, placeholder } = validateEnv(specs, fileEnv);

  const targetLabel = target.toUpperCase();

  if (ok) {
    console.log(`✅  check-env [${targetLabel}]: all ${specs.length} required variables are set`);
    return 0;
  }

  // Report errors
  console.error(`\n❌  check-env [${targetLabel}]: environment validation failed\n`);

  if (missing.length > 0) {
    console.error(`Missing variables (not set in ${envFile} or process environment):`);
    for (const name of missing) {
      const spec = specs.find((s) => s.name === name);
      console.error(`  • ${name}${spec?.description ? `  — ${spec.description}` : ''}`);
    }
    console.error('');
  }

  if (placeholder.length > 0) {
    console.error(`Placeholder values (must be replaced before deploying):`);
    for (const name of placeholder) {
      const spec = specs.find((s) => s.name === name);
      const rawValue = process.env[name] ?? fileEnv[name] ?? '';
      // Mask secrets in output so real values are never echoed in CI logs
      const displayValue = spec?.secret
        ? '[redacted]'
        : rawValue.length > 50
          ? rawValue.slice(0, 50) + '…'
          : rawValue;
      console.error(
        `  • ${name}="${displayValue}"${spec?.description ? `  — ${spec.description}` : ''}`
      );
    }
    console.error('');
  }

  console.error(
    `Fix these values in ${envFile} (copy from .env.example and fill in real values),\n` +
      `then re-run: node scripts/check-env.js --target ${target}\n`
  );

  return 1;
}

// Run when invoked directly (not imported as a module)
if (process.argv[1] && process.argv[1].endsWith('check-env.js')) {
  process.exit(run());
}
