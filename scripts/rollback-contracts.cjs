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
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
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

/**
 * Verify a contract exists on-chain by reading its instance ledger entry
 * (persistent `LedgerKeyContractInstance`) from Soroban RPC.
 *
 * Resolves to true when the entry exists, false when the RPC reports it as
 * missing, and throws on transport errors so the caller can tell "missing"
 * apart from "could not check".
 */
async function contractExistsOnChain(contractId, rpcUrl) {
  const { rpc, xdr } = require('@stellar/stellar-sdk');
  const server = new rpc.Server(rpcUrl, { allowHttp: rpcUrl.startsWith('http://') });
  try {
    const entry = await server.getContractData(
      contractId,
      xdr.ScVal.scvLedgerKeyContractInstance(),
      rpc.Durability.Persistent
    );
    return Boolean(entry && entry.val);
  } catch (err) {
    // The SDK rejects with a { code: 404 } object when the entry is absent.
    if (err && (err.code === 404 || /not found/i.test(String(err.message || err)))) {
      return false;
    }
    throw err instanceof Error ? err : new Error(JSON.stringify(err));
  }
}

// ---------------------------------------------------------------------------
// Environment / ConfigMap updates.
// ---------------------------------------------------------------------------

function updateEnvFile(envFilePath, contractIds, dryRun) {
  const existing = fs.existsSync(envFilePath)
    ? fs.readFileSync(envFilePath, 'utf8')
    : '';

  const lines = existing.split(/\r?\n/);
  // Drop the empty element produced by a trailing newline so appended keys
  // follow the last line directly; the newline is re-added on write.
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  const keys = Object.keys(contractIds);
  const seen = new Set();

  const updated = lines.map((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) return line;
    const eq = trimmed.indexOf('=');
    if (eq === -1) return line;
    const key = trimmed.slice(0, eq).trim();
    if (Object.prototype.hasOwnProperty.call(contractIds, key)) {
      seen.add(key);
      return `${key}=${contractIds[key]}`;
    }
    return line;
  });

  // Append any keys that were not already present.
  for (const key of keys) {
    if (!seen.has(key)) {
      updated.push(`${key}=${contractIds[key]}`);
    }
  }

  const contents = updated.join('\n') + '\n';

  if (dryRun) {
    process.stdout.write(
      `[dry-run] Would write ${envFilePath}:\n${contents}\n`
    );
    return;
  }

  fs.writeFileSync(envFilePath, contents, 'utf8');
  process.stdout.write(`[ok] Updated env file: ${envFilePath}\n`);
}

function updateConfigMap(name, namespace, contractIds, dryRun) {
  // Merge-patch only the contract ID keys so the rest of the ConfigMap
  // (NODE_ENV, PORT, RPC URLs, ...) is left untouched.
  const patch = JSON.stringify({ data: contractIds });
  const args = ['patch', 'configmap', name, '--namespace', namespace, '--type', 'merge', '-p', patch];

  if (dryRun) {
    process.stdout.write(
      `[dry-run] Would patch ConfigMap ${namespace}/${name} with:\n` +
        Object.entries(contractIds)
          .map(([k, v]) => `  ${k}=${v}`)
          .join('\n') +
        '\n'
    );
    return;
  }

  try {
    execFileSync('kubectl', args, { encoding: 'utf8', stdio: ['ignore', 'inherit', 'inherit'] });
    process.stdout.write(
      `[ok] Updated ConfigMap: ${namespace}/${name}\n` +
        '     Pods only read envFrom at start-up; run `kubectl rollout restart deployment/backend`\n' +
        '     to pick up the new contract IDs.\n'
    );
  } catch (err) {
    throw new Error(
      `Failed to update ConfigMap ${namespace}/${name}: ${err.message}`
    );
  }
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`[error] ${err.message}\n\n`);
    printUsage();
    process.exit(1);
  }

  const backupPath = path.resolve(args.backup);
  process.stdout.write(`[info] Reading backup: ${backupPath}\n`);

  let previous;
  try {
    previous = readEnvFile(backupPath);
  } catch (err) {
    process.stderr.write(`[error] ${err.message}\n`);
    process.exit(1);
  }

  // Only consider keys that look like contract IDs.
  const contractIds = {};
  for (const [key, value] of Object.entries(previous)) {
    if (key.endsWith('_CONTRACT_ID') || key.endsWith('_CONTRACT')) {
      if (!isValidContractId(value)) {
        process.stderr.write(
          `[error] Backup key ${key} has invalid contract ID: ${value}\n`
        );
        process.exit(1);
      }
      contractIds[key] = value;
    }
  }

  if (Object.keys(contractIds).length === 0) {
    process.stderr.write(
      '[error] No *_CONTRACT_ID entries found in backup file.\n'
    );
    process.exit(1);
  }

  process.stdout.write(
    `[info] Found ${Object.keys(contractIds).length} contract ID(s) in backup.\n`
  );

  // Verify each old contract still exists on-chain.
  let allVerified = true;
  for (const [key, id] of Object.entries(contractIds)) {
    process.stdout.write(`[info] Verifying ${key} = ${id} ... `);
    let exists = false;
    try {
      exists = await contractExistsOnChain(id, args.rpcUrl);
    } catch (err) {
      process.stdout.write('\n');
      process.stderr.write(
        `[error] Verification failed for ${key} (${id}): ${err.message}\n`
      );
      allVerified = false;
      continue;
    }
    process.stdout.write(exists ? 'OK\n' : 'MISSING\n');
    if (!exists) allVerified = false;
  }

  if (!allVerified) {
    process.stderr.write(
      '\n[error] One or more previous contracts could not be verified on-chain.\n' +
        '        Refusing to roll back to unverified contract IDs.\n' +
        '        (Note: Soroban contracts are immutable and are never removed\n' +
        '         from the chain, so a MISSING result usually indicates a wrong\n' +
        '         network/RPC URL or a malformed contract ID.)\n'
    );
    process.exit(2);
  }

  process.stdout.write('[ok] All previous contracts verified on-chain.\n');

  // Apply the rollback.
  try {
    updateEnvFile(args.envFile, contractIds, args.dryRun);
    if (args.configmap) {
      updateConfigMap(
        args.configmap,
        args.namespace,
        contractIds,
        args.dryRun
      );
    }
  } catch (err) {
    process.stderr.write(`[error] ${err.message}\n`);
    process.exit(3);
  }

  process.stdout.write(
    '\n[ok] Rollback complete. Backend now references the previous contract IDs.\n' +
      '     Reminder: the newer contracts remain deployed on-chain (Soroban\n' +
      '     contracts are immutable); they are simply no longer referenced.\n'
  );
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`[fatal] ${err && err.stack ? err.stack : err}\n`);
    process.exit(1);
  });
}

module.exports = {
  parseEnvFile,
  readEnvFile,
  parseArgs,
  isValidContractId,
  contractExistsOnChain,
  updateEnvFile,
  updateConfigMap,
};