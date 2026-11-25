#!/usr/bin/env node
/**
 * scripts/check-env.js
 *
 * Validates that all required environment variables for a given deployment
 * target are present and have been filled in (no placeholder values).
 *
 * Usage:
 *   node scripts/check-env.js [--target <compose|k8s|railway>] [--env-file <path>]
 *                             [--json] [--strict|--mainnet]
 *
 * Options:
 *   --target   Deployment target to validate (default: compose)
 *              compose  — local Docker Compose stack
 *              k8s      — Kubernetes / Kustomize deploy
 *              railway  — Railway backend deploy
 *   --env-file Path to the .env file to check (default: .env)
 *   --json     Emit a machine-readable JSON result (no secret values) to stdout
 *   --strict   Enable strict mainnet checks: reject testnet network identifiers
 *              and insecure (http://) remote endpoints. Alias: --mainnet
 *   --help     Print this help message
 *
 * Exit codes:
 *   0  Required variables are set, non-placeholder, and valid for the target
 *   1  Variables are missing, contain placeholders, have invalid URLs, or fail
 *      strict mainnet checks; or command-line arguments are invalid
 *
 * Duplicate keys:
 *   If a key is assigned more than once in the env file, every occurrence is
 *   reported with its line number. The last assignment in the file wins, and
 *   process.env always takes precedence over any file value.
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
import { StrKey, Keypair } from '@stellar/stellar-sdk';

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

/**
 * Returns true if the value should be treated as missing: undefined, null,
 * empty, or whitespace-only (including quoted whitespace such as `" "`).
 *
 * Only the presence check uses this; the original value is preserved for
 * semantic checks so secrets that legitimately contain internal spaces are
 * not altered.
 *
 * @param {string|undefined|null} value
 * @returns {boolean}
 */
function isBlank(value) {
  if (value === undefined || value === null) return true;
  if (typeof value !== 'string') return false;
  if (value.trim() !== '') return false;
  // Quoted whitespace, e.g. `" "` or `'  '`, is also considered blank.
  const unquoted = value.replace(/^(['"])(.*)\1$/s, '$2');
  return unquoted.trim() === '';
}

// ---------------------------------------------------------------------------
// Semantic validation helpers
// ---------------------------------------------------------------------------

/**
 * Supported Stellar network identifiers. Values are compared case-insensitively.
 * @type {string[]}
 */
const SUPPORTED_NETWORKS = ['testnet', 'mainnet', 'futurenet', 'standalone'];

/**
 * Field kinds that receive StrKey validation.
 * @type {Record<string, 'publicKey'|'secretSeed'|'contract'>}
 */
const STRKEY_FIELDS = {
  STELLAR_PUBLIC_KEY: 'publicKey',
  PAY_TO: 'publicKey',
  STELLAR_SECRET_KEY: 'secretSeed',
  AGENT_SECRET_KEY: 'secretSeed',
  REGISTRY_SECRET_KEY: 'secretSeed',
  STELLAR_CONTRACT_VAULT_REGISTRY: 'contract',
  STELLAR_CONTRACT_ACCESS_LEASE: 'contract',
  STELLAR_CONTRACT_SUBSCRIPTION: 'contract',
  USDC_CONTRACT_ID: 'contract',
};

/**
 * Validate a StrKey-encoded value for the given kind.
 *
 * @param {string} value
 * @param {'publicKey'|'secretSeed'|'contract'} kind
 * @returns {boolean}
 */
function isValidStrKey(value, kind) {
  try {
    if (kind === 'publicKey') return StrKey.isValidEd25519PublicKey(value);
    if (kind === 'secretSeed') return StrKey.isValidEd25519SecretSeed(value);
    if (kind === 'contract') return StrKey.isValidContract(value);
  } catch {
    return false;
  }
  return false;
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

const URL_PROTOCOLS = {
  compose: {
    SOROBAN_RPC_URL: ['http:', 'https:'],
    SUPABASE_URL: ['http:', 'https:'],
  },
  k8s: {
    SOROBAN_RPC_URL: ['https:'],
    SUPABASE_URL: ['https:'],
  },
  railway: {
    DATABASE_URL: ['postgres:', 'postgresql:'],
    SOROBAN_RPC_URL: ['https:'],
    SUPABASE_URL: ['https:'],
  },
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
 * Duplicate keys: the last assignment in the file wins (deterministic policy).
 * Call parseEnvFileDetailed() to also obtain per-key occurrence line numbers.
 *
 * @param {string} filePath
 * @returns {Record<string, string>}
 */
export function parseEnvFile(filePath) {
  return parseEnvFileDetailed(filePath).env;
}

/**
 * Parse a .env file, returning both the resolved key→value map and the line
 * numbers at which each key was assigned (in file order).
 *
 * @param {string} filePath
 * @returns {{ env: Record<string, string>, occurrences: Record<string, number[]> }}
 */
export function parseEnvFileDetailed(filePath) {
  /** @type {Record<string, string>} */
  const env = {};
  /** @type {Record<string, number[]>} */
  const occurrences = {};
  if (!existsSync(filePath)) return { env, occurrences };
  const content = readFileSync(filePath, 'utf8');
  const lines = content.split('\n');
  for (let lineNo = 0; lineNo < lines.length; lineNo++) {
    let line = lines[lineNo].trim();
    if (!line || line.startsWith('#')) continue;
    if (/^export\s+/.test(line)) line = line.replace(/^export\s+/, '');
    const eqIdx = line.indexOf('=');
    if (eqIdx === -1) continue;
    const key = line.slice(0, eqIdx).trim();
    if (!key) continue;
    let value = line.slice(eqIdx + 1).trim();
    if (value.startsWith('"') || value.startsWith("'")) {
      const quote = value[0];
      const closingQuote = value.lastIndexOf(quote);
      const trailing = value.slice(closingQuote + 1);
      if (closingQuote > 0 && (!trailing || /^\s+#/.test(trailing))) {
        value = value.slice(1, closingQuote);
      }
    } else {
      const commentIdx = value.search(/\s+#/);
      if (commentIdx !== -1) value = value.slice(0, commentIdx).trim();
    }
    env[key] = value;
    (occurrences[key] ??= []).push(lineNo + 1);
  }
  return { env, occurrences };
}

/**
 * Return the keys assigned more than once, with their 1-based line numbers.
 *
 * @param {Record<string, number[]>} occurrences
 * @returns {Array<{ key: string, lines: number[] }>}
 */
export function findDuplicateKeys(occurrences) {
  return Object.keys(occurrences)
    .filter((key) => occurrences[key].length > 1)
    .sort()
    .map((key) => ({ key, lines: occurrences[key].slice() }));
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} ValidationResult
 * @property {boolean}  ok
 * @property {string[]} missing     Variables not set at all
 * @property {string[]} placeholder Variables set to a placeholder value
 * @property {string[]} invalidUrl  URL values with invalid syntax or protocols
 * @property {string[]} testnet     Variables identifying a testnet (strict mode)
 * @property {string[]} insecureUrl Remote endpoints using http:// (strict mode)
 */

/** Hostnames considered local (allowed to use http:// even in strict mode). */
const LOCAL_HOSTNAMES = new Set(['localhost', '127.0.0.1', '::1', '[::1]']);

/**
 * Returns true if the hostname refers to the local machine.
 *
 * @param {string} hostname
 * @returns {boolean}
 * @property {string[]} missing        Variables not set at all (or blank/whitespace-only)
 * @property {string[]} placeholder    Variables set to a placeholder value
 * @property {string[]} invalidUrl     URL values with invalid syntax or protocols
 * @property {string[]} invalidNetwork STELLAR_NETWORK values outside the allowlist
 * @property {string[]} invalidKey     StrKey fields with invalid encoding/checksum
 * @property {string[]} keyMismatch    STELLAR_PUBLIC_KEY does not match STELLAR_SECRET_KEY
 */
function isLocalHost(hostname) {
  return LOCAL_HOSTNAMES.has(hostname.toLowerCase());
}

/**
 * Validate a set of variable specs against the merged env (file + process).
 *
 * @param {VarSpec[]}            specs
 * @param {Record<string,string>} fileEnv
 * @param {'compose'|'k8s'|'railway'} target
 * @param {{ strict?: boolean }} [options]
 * @returns {ValidationResult}
 */
export function validateEnv(specs, fileEnv, target, options = {}) {
  const strict = options.strict === true;
  const missing = [];
  const placeholder = [];
  const invalidUrl = [];
  const testnet = [];
  const insecureUrl = [];
  const invalidNetwork = [];
  const invalidKey = [];
  const keyMismatch = [];

  /** @type {Record<string, string>} */
  const resolved = {};

  for (const spec of specs) {
    // process.env takes precedence over the file (mirrors how dotenv works in apps)
    const value = process.env[spec.name] ?? fileEnv[spec.name];
    if (isBlank(value)) {
      missing.push(spec.name);
      continue;
    }
    resolved[spec.name] = value;
    if (isPlaceholder(value)) {
      placeholder.push(spec.name);
      continue;
    }
    const allowedProtocols = URL_PROTOCOLS[target][spec.name];
    if (allowedProtocols) {
      try {
        const url = new URL(value);
        if (!allowedProtocols.includes(url.protocol) || !url.hostname) {
          invalidUrl.push(spec.name);
        } else if (strict && url.protocol === 'http:' && !isLocalHost(url.hostname)) {
          insecureUrl.push(spec.name);
        }
      } catch {
        invalidUrl.push(spec.name);
      }
    }
    if (spec.name === 'STELLAR_NETWORK') {
      if (!SUPPORTED_NETWORKS.includes(value.trim().toLowerCase())) invalidNetwork.push(spec.name);
      if (strict && /testnet/i.test(value)) testnet.push(spec.name);
    }
    const strKeyKind = STRKEY_FIELDS[spec.name];
    if (strKeyKind && !isValidStrKey(value, strKeyKind)) invalidKey.push(spec.name);
  }

  // Cross-field check: derive the public key from the secret and compare.
  // Only run when both values are present and individually valid, and never
  // include either key or derived material in the result.
  const secret = resolved.STELLAR_SECRET_KEY;
  const publicKey = resolved.STELLAR_PUBLIC_KEY;
  if (
    secret !== undefined &&
    publicKey !== undefined &&
    !invalidKey.includes('STELLAR_SECRET_KEY') &&
    !invalidKey.includes('STELLAR_PUBLIC_KEY')
  ) {
    try {
      const derived = Keypair.fromSecret(secret).publicKey();
      if (derived !== publicKey) {
        keyMismatch.push('STELLAR_PUBLIC_KEY');
      }
    } catch {
      // A secret that cannot be parsed was already reported via invalidKey.
      if (!invalidKey.includes('STELLAR_SECRET_KEY')) {
        invalidKey.push('STELLAR_SECRET_KEY');
      }
    }
  }

  return {
    ok: [missing, placeholder, invalidUrl, testnet, insecureUrl, invalidNetwork, invalidKey, keyMismatch].every(items => items.length === 0),
    missing, placeholder, invalidUrl, testnet, insecureUrl, invalidNetwork, invalidKey, keyMismatch,
  };
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

/**
 * Parse process.argv into an options object.
 *
 * @param {string[]} argv  process.argv.slice(2)
 * @returns {{ target: string, envFile: string, help: boolean, json: boolean, strict: boolean }}
 */
export function parseArgs(argv) {
  let target = 'compose';
  let envFile = '.env';
  let help = false;
  let json = false;
  let strict = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      help = true;
    } else if (arg === '--json') {
      json = true;
    } else if (arg === '--strict' || arg === '--mainnet') {
      strict = true;
    } else if (arg === '--target' || arg === '-t') {
      const value = argv[++i];
      if (!value || value.startsWith('-')) {
        throw new Error(`option "${arg}" requires a value`);
      }
      target = value;
    } else if (arg === '--env-file') {
      const value = argv[++i];
      if (!value || value.startsWith('-')) {
        throw new Error(`option "${arg}" requires a value`);
      }
      envFile = value;
    } else if (arg.startsWith('--target=')) {
      target = arg.slice('--target='.length);
      if (!target) throw new Error('option "--target" requires a value');
    } else if (arg.startsWith('--env-file=')) {
      envFile = arg.slice('--env-file='.length);
      if (!envFile) throw new Error('option "--env-file" requires a value');
    } else {
      throw new Error(`unknown argument "${arg}"`);
    }
  }

  return { target, envFile, help, json, strict };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const HELP_TEXT = `
check-env.js — Validate .env variables for a deployment target

Usage:
  node scripts/check-env.js [--target <compose|k8s|railway>] [--env-file <path>]
                            [--json] [--strict|--mainnet]

Options:
  --target   Deployment target (default: compose)
             compose  — local Docker Compose stack
             k8s      — Kubernetes / Kustomize deploy
             railway  — Railway backend deploy
  --env-file Path to .env file (default: .env)
  --json     Emit a machine-readable JSON result (no secret values) to stdout
  --strict   Strict mainnet checks: reject testnet network identifiers and
             insecure (http://) remote endpoints. Localhost is still allowed.
             Alias: --mainnet
  --help     Print this help message

Duplicate keys:
  Duplicate assignments in the env file are reported with line numbers.
  The last file assignment wins; process.env always takes precedence.

Exit codes:
  0  All checks passed
  1  Missing variables, placeholders, invalid URLs, strict-mode failures,
     or invalid arguments
  1  Missing variables, placeholders, invalid URLs, invalid Stellar
     network/keys, key mismatches, or invalid arguments
`.trim();

/**
 * Build the machine-readable result object. Contains only error codes and
 * variable names — never secret values.
 *
 * @param {Object} params
 * @param {string} params.target
 * @param {boolean} params.strict
 * @param {boolean} params.ok
 * @param {Array<{ key: string, lines: number[] }>} params.duplicates
 * @param {ValidationResult} params.result
 * @returns {Object}
 */
export function buildJsonResult({ target, strict, ok, duplicates, result }) {
  /** @type {Array<{ code: string, variables: string[] }>} */
  const errors = [];
  if (result.missing.length > 0) {
    errors.push({ code: 'MISSING', variables: result.missing });
  }
  if (result.placeholder.length > 0) {
    errors.push({ code: 'PLACEHOLDER', variables: result.placeholder });
  }
  if (result.invalidUrl.length > 0) {
    errors.push({ code: 'INVALID_URL', variables: result.invalidUrl });
  }
  if (result.testnet.length > 0) {
    errors.push({ code: 'TESTNET_NOT_ALLOWED', variables: result.testnet });
  }
  if (result.insecureUrl.length > 0) {
    errors.push({ code: 'INSECURE_ENDPOINT', variables: result.insecureUrl });
  }
  for (const [code, variables] of [
    ['INVALID_NETWORK', result.invalidNetwork],
    ['INVALID_KEY', result.invalidKey],
    ['KEY_MISMATCH', result.keyMismatch],
  ]) {
    if (variables.length) errors.push({ code, variables });
  }
  return {
    target,
    strict,
    ok,
    errors,
    duplicates: duplicates.map(({ key, lines }) => ({ key, lines })),
  };
}

/**
 * Run the CLI. Exported so it can be stubbed in tests.
 *
 * @param {string[]} argv  Argument array (default: process.argv.slice(2))
 * @param {string}   [cwd] Working directory for resolving --env-file (default: process.cwd())
 * @returns {number} Exit code
 */
export function run(argv = process.argv.slice(2), cwd = process.cwd()) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`check-env: ${error.message}`);
    return 1;
  }
  const { target, envFile, help, json, strict } = options;

  if (help) {
    console.log(HELP_TEXT);
    return 0;
  }

  const validTargets = Object.keys(TARGETS);
  if (!validTargets.includes(target)) {
    if (json) {
      console.log(
        JSON.stringify({
          target,
          strict,
          ok: false,
          errors: [{ code: 'INVALID_TARGET', variables: [] }],
          duplicates: [],
        })
      );
    } else {
      console.error(
        `check-env: unknown target "${target}". Valid targets: ${validTargets.join(', ')}`
      );
    }
    return 1;
  }

  const resolvedEnvFile = resolve(cwd, envFile);
  const { env: fileEnv, occurrences } = parseEnvFileDetailed(resolvedEnvFile);
  const duplicates = findDuplicateKeys(occurrences);
  const specs = TARGETS[target];

  const result = validateEnv(specs, fileEnv, target, { strict });
  const { ok, missing, placeholder, invalidUrl, testnet, insecureUrl, invalidNetwork, invalidKey, keyMismatch } = result;

  const targetLabel = target.toUpperCase();

  if (json) {
    console.log(JSON.stringify(buildJsonResult({ target, strict, ok, duplicates, result })));
    return ok ? 0 : 1;
  }

  if (duplicates.length > 0) {
    console.error(`⚠️   check-env [${targetLabel}]: duplicate keys in ${envFile}\n`);
    for (const { key, lines } of duplicates) {
      console.error(`  • ${key} assigned on lines ${lines.join(', ')} (last assignment wins)`);
    }
    console.error('');
  }

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

  if (invalidUrl.length > 0) {
    console.error(`Invalid URL values (must use an allowed protocol):`);
    for (const name of invalidUrl) {
      console.error(`  • ${name} (allowed: ${URL_PROTOCOLS[target][name].join(', ')})`);
    }
    console.error('');
  }

  if (testnet.length > 0) {
    console.error(`Testnet configuration rejected in strict mainnet mode:`);
    for (const name of testnet) {
      console.error(`  • ${name} must not identify a testnet`);
    }
    console.error('');
  }

  if (invalidNetwork.length > 0) {
    console.error(`Invalid STELLAR_NETWORK values (unsupported network):`);
    for (const name of invalidNetwork) {
      console.error(
        `  • ${name}="${process.env[name] ?? fileEnv[name] ?? ''}"` +
          `  — must be one of: ${SUPPORTED_NETWORKS.join(', ')}`
      );
    }
    console.error('');
  }

  if (insecureUrl.length > 0) {
    console.error(`Insecure remote endpoints rejected in strict mainnet mode:`);
    for (const name of insecureUrl) {
      console.error(`  • ${name} must use https:// for non-local hosts`);
    }
    console.error('');
  }

  if (invalidKey.length > 0) {
    console.error(`Invalid Stellar key/contract values (bad encoding or checksum):`);
    for (const name of invalidKey) {
      const spec = specs.find((s) => s.name === name);
      const kind = STRKEY_FIELDS[name];
      const expected =
        kind === 'publicKey'
          ? 'a valid Ed25519 public key (G...)'
          : kind === 'secretSeed'
            ? 'a valid Ed25519 secret seed (S...)'
            : 'a valid contract ID (C...)';
      // Never echo secret values; non-secret values are shown truncated.
      const rawValue = process.env[name] ?? fileEnv[name] ?? '';
      const displayValue = spec?.secret
        ? '[redacted]'
        : rawValue.length > 50
          ? rawValue.slice(0, 50) + '…'
          : rawValue;
      console.error(`  • ${name}="${displayValue}"  — expected ${expected}`);
    }
    console.error('');
  }

  if (keyMismatch.length > 0) {
    console.error(
      `STELLAR_PUBLIC_KEY does not match the public key derived from STELLAR_SECRET_KEY.\n` +
        `  • Ensure both values come from the same Stellar keypair (values are not shown).`
    );
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
