#!/usr/bin/env node
'use strict';

/**
 * rollback-contracts.cjs
 *
 * Rolls the backend back to a previous set of Soroban contract IDs.
 *
 * IMPORTANT — Soroban contracts are immutable:
 *   Once a contract is deployed to the Stellar/Soroban network it cannot be
 *   undeployed, upgraded in place, or deleted. "Rolling back a deployment"
 *   therefore does NOT mean removing the new contracts from the chain. It
 *   means pointing the backend (environment variables / Kubernetes ConfigMap)
 *   back at the *previous* contract IDs so the application talks to the older,
 *   known-good contract instances again.
 *
 *   The newly deployed contracts simply become unused. They remain on-chain
 *   forever and can be re-adopted later by pointing the backend at them again.
 *
 * What this script does:
 *   1. Reads a previous contract-ids.env backup file.
 *   2. Verifies each old contract still exists on-chain (via Soroban RPC).
 *   3. Updates the backend environment / ConfigMap to the previous contract IDs.
 *
 * Contract-ID keys are normalised to the canonical `STELLAR_CONTRACT_*` names
 * the backend reads, so backups written by either deploy path are supported:
 *   STELLAR_CONTRACT_VAULT_REGISTRY   (canonical; both deploy paths)
 *   VAULT_REGISTRY_CONTRACT_ID        (legacy SDK deployer)
 *   vault_registry                    (legacy bash deployer)
 *
 * The canonical keys are managed in Git in `k8s/configmap.yaml` (as
 * placeholders). After a contract deploy, update those keys in the ConfigMap
 * and re-apply it so the running config matches the committed state:
 *
 *   # 1. Deploy contracts and capture the new IDs (writes a backup file).
 *   node scripts/deploy-contracts.cjs
 *
 *   # 2. Update the contract-ID keys in k8s/configmap.yaml to the new IDs.
 *   #    (Edit the STELLAR_CONTRACT_* values, then commit the change.)
 *
 *   # 3. Re-apply the ConfigMap so the cluster matches Git.
 *   kubectl apply -f k8s/configmap.yaml
 *
 *   # 4. Restart the backend so it picks up the new values.
 *   kubectl rollout restart deployment/backend -n synapsvault
 *
 * To roll back, run this script with `--configmap` (see below) and then
 * re-apply the ConfigMap from Git once the committed IDs are reverted.
 *
 * Usage:
 *   node scripts/rollback-contracts.cjs \
 *     --backup ./backups/contract-ids.env.2024-01-01T00-00-00Z \
 *     [--target-env .env] \
 *     [--configmap my-backend-config] \
 *     [--namespace synapsvault] \
 *     [--rpc-url https://soroban-testnet.stellar.org] \
 *     [--network testnet] \
 *     [--dry-run]
 *
 * Exit codes:
 *   0  success
 *   1  usage / configuration error
 *   2  verification failure (one or more old contracts missing on-chain)
 *   3  environment / ConfigMap update failure
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// ---------------------------------------------------------------------------
// Minimal .env parser (no external dependencies).
// ---------------------------------------------------------------------------

function parseEnvFile(contents) {
  const result = {};
  const lines = contents.split(/\r?\n/);
  for (const rawLine of lines) {
    let line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    // Strip leading 'export ' prefix (handles bash-style export KEY=value)
    if (line.startsWith('export ')) {
      line = line.slice(7).trim();
    }
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    // Strip surrounding quotes if present.
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

function readEnvFile(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Env file not found: ${filePath}`);
  }
  return parseEnvFile(fs.readFileSync(filePath, 'utf8'));
}

// ---------------------------------------------------------------------------
// Argument parsing.
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = {
    backup: null,
    envFile: '.env',
    configmap: null,
    namespace: 'synapsvault',
    rpcUrl: process.env.SOROBAN_RPC_URL || null,
    network: process.env.STELLAR_NETWORK || 'testnet',
    dryRun: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) {
        throw new Error(`Missing value for argument: ${arg}`);
      }
      return argv[++i];
    };

    switch (arg) {
      case '--backup':
        args.backup = next();
        break;
      // Node >= 22 intercepts a literal `--env-file` anywhere in argv, so
      // `--target-env` is the portable spelling; `--env-file` is kept for Node 20.
      case '--target-env':
      case '--env-file':
        args.envFile = next();
        break;
      case '--configmap':
        args.configmap = next();
        break;
      case '--namespace':
        args.namespace = next();
        break;
      case '--rpc-url':
        args.rpcUrl = next();
        break;
      case '--network':
        args.network = next();
        break;
      case '--dry-run':
        args.dryRun = true;
        break;
      case '--help':
      case '-h':
        printUsage();
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.backup) {
    throw new Error('Missing required argument: --backup <path>');
  }

  if (!args.rpcUrl) {
    args.rpcUrl = DEFAULT_RPC_URLS[args.network];
    if (!args.rpcUrl) {
      throw new Error(`No default RPC URL for network "${args.network}"; pass --rpc-url`);
    }
  }

  return args;
}

function printUsage() {
  process.stdout.write(
    [
      'Usage: node scripts/rollback-contracts.cjs --backup <path> [options]',
      '',
      'Options:',
      '  --backup <path>       Path to the previous contract-ids.env backup (required)',
      '  --target-env <path>   Backend .env file to update (default: .env)',
      '                        (alias: --env-file, which newer Node versions intercept)',
      '  --configmap <name>    Kubernetes ConfigMap to update (optional)',
      '  --namespace <ns>      Kubernetes namespace (default: synapsvault)',
      '  --rpc-url <url>       Soroban RPC endpoint (default: $SOROBAN_RPC_URL, or the',
      '                        public RPC for testnet/futurenet; required for mainnet)',
      '  --network <name>      Stellar network name (testnet|mainnet|futurenet)',
      '  --dry-run             Verify and report without writing changes',
      '  -h, --help            Show this help',
      '',
      'Note: Soroban contracts are immutable. This script does not undeploy',
      'anything; it reverts the backend contract-ID references only.',
      '',
      'After a contract deploy, update the STELLAR_CONTRACT_* keys in',
      'k8s/configmap.yaml and re-apply it (kubectl apply -f k8s/configmap.yaml)',
      'so the committed ConfigMap matches the running config.',
      '',
    ].join('\n')
  );
}

// ---------------------------------------------------------------------------
// Contract ID validation & on-chain verification.
// ---------------------------------------------------------------------------

const CONTRACT_ID_RE = /^C[A-Z2-7]{55}$/;

const DEFAULT_RPC_URLS = {
  testnet: 'https://soroban-testnet.stellar.org',
  futurenet: 'https://rpc-futurenet.stellar.org',
};

function isValidContractId(id) {
  return typeof id === 'string' && CONTRACT_ID_RE.test(id);
}

// Canonical env var prefix for deployed contract IDs (the names the backend
// reads), e.g. `vault_registry` -> `STELLAR_CONTRACT_VAULT_REGISTRY`.
const CONTRACT_ENV_PREFIX = 'STELLAR_CONTRACT_';

// Legacy keys whose canonical target is not a plain prefix/suffix rewrite:
// `REGISTRY_CONTRACT_ID` is the older name for the vault registry contract
// (see docs/ENVIRONMENT-VARIABLES.md).
const CONTRACT_KEY_ALIASES = {
  REGISTRY_CONTRACT_ID: `${CONTRACT_ENV_PREFIX}VAULT_REGISTRY`,
  REGISTRY_CONTRACT: `${CONTRACT_ENV_PREFIX}VAULT_REGISTRY`,
};

/**
 * Map any recognised contract-ID key to its canonical `STELLAR_CONTRACT_*`
 * name, so backups written by any deploy path can be rolled back.
 *
 * Returns null when `key` is not a contract-ID reference.
 */
function canonicalContractKey(key, value) {
  if (typeof key !== 'string') return null;

  if (key.startsWith(CONTRACT_ENV_PREFIX)) {
    const stem = key.slice(CONTRACT_ENV_PREFIX.length);
    return stem ? key : null;
  }

  if (Object.prototype.hasOwnProperty.call(CONTRACT_KEY_ALIASES, key)) {
    return CONTRACT_KEY_ALIASES[key];
  }

  for (const suffix of ['_CONTRACT_ID', '_CONTRACT']) {
    if (key.endsWith(suffix)) {
      const stem = key.slice(0, -suffix.length);
      return stem ? `${CONTRACT_ENV_PREFIX}${stem}` : null;
    }
  }

  // Bare lower-case contract names (legacy bash deployer), e.g. `vault_registry`.
  if (/^[a-z][a-z0-9_]*$/.test(key) && isValidContractId(value)) {
    return `${CONTRACT_ENV_PREFIX}${key.toUpperCase()}`;
  }

  return null;
}

function updateEnvFile(filePath, ids, dryRun) {
  const content = fs.existsSync(filePath) ? fs.readFileSync(filePath, 'utf8') : '';
  const seen = new Set();
  const lines = content
    .replace(/\n$/, '')
    .split('\n')
    .filter((line, i) => content || i > 0);
  const updated = lines.map((line) => {
    const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/);
    if (!match) return line;
    const key = match[1];
    const canonical = canonicalContractKey(key, parseEnvFile(line)[key]);
    if (!canonical || !Object.hasOwn(ids, canonical)) return line;
    if (key === canonical) seen.add(key);
    return `${key}=${ids[canonical]}`;
  });
  for (const [key, value] of Object.entries(ids)) {
    if (!seen.has(key)) updated.push(`${key}=${value}`);
  }
  if (dryRun) {
    console.log(`[dry-run] Would update ${path.resolve(filePath)}`);
    return;
  }
  // Rename a protected temporary file so interrupted writes leave the original intact.
  const temp = `${filePath}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(temp, updated.join('\n') + '\n', { mode: 0o600, flag: 'wx' });
    fs.renameSync(temp, filePath);
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const ids = {};
  for (const [key, value] of Object.entries(readEnvFile(args.backup))) {
    const canonical = canonicalContractKey(key, value);
    if (!canonical) continue;
    if (!/^STELLAR_CONTRACT_[A-Z0-9_]+$/.test(canonical) || !isValidContractId(value)) {
      throw new Error(`Invalid contract reference: ${key}`);
    }
    if (ids[canonical] && ids[canonical] !== value)
      throw new Error(`Conflicting IDs for ${canonical}`);
    ids[canonical] = value;
  }
  if (!Object.keys(ids).length) throw new Error('Backup contains no contract IDs');
  const { rpc, xdr } = require('@stellar/stellar-sdk');
  const server = new rpc.Server(args.rpcUrl, { allowHttp: args.rpcUrl.startsWith('http://') });
  try {
    for (const id of Object.values(ids)) {
      await server.getContractData(
        id,
        xdr.ScVal.scvLedgerKeyContractInstance(),
        rpc.Durability.Persistent
      );
    }
  } catch (err) {
    process.exitCode = 2;
    throw new Error(`On-chain verification failed: ${err.message}`);
  }
  try {
    if (args.configmap && !args.dryRun) {
      execFileSync(
        'kubectl',
        [
          '--namespace',
          args.namespace,
          'patch',
          'configmap',
          args.configmap,
          '--type=merge',
          '-p',
          JSON.stringify({ data: ids }),
        ],
        { stdio: 'inherit' }
      );
    }
    updateEnvFile(args.envFile, ids, args.dryRun);
  } catch (err) {
    process.exitCode = 3;
    throw err;
  }
  console.log(
    args.dryRun
      ? 'Rollback verified (dry run).'
      : 'Contract references restored; restart the backend to apply.'
  );
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message);
    process.exitCode ||= 1;
  });
}

module.exports = {
  parseEnvFile,
  isValidContractId,
  canonicalContractKey,
  parseArgs,
  updateEnvFile,
};
