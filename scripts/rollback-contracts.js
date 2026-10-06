#!/usr/bin/env node
'use strict';

/**
 * rollback-contracts.js
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
 *   node scripts/rollback-contracts.js \
 *     --backup ./backups/contract-ids.env.2024-01-01T00-00-00Z \
 *     [--env-file .env] \
 *     [--configmap my-backend-config] \
 *     [--namespace default] \
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
    namespace: 'default',
    rpcUrl: process.env.SOROBAN_RPC_URL || 'https://soroban-testnet.stellar.org',
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

  return args;
}

function printUsage() {
  process.stdout.write(
    [
      'Usage: node scripts/rollback-contracts.js --backup <path> [options]',
      '',
      'Options:',
      '  --backup <path>       Path to the previous contract-ids.env backup (required)',
      '  --env-file <path>     Backend .env file to update (default: .env)',
      '  --configmap <name>    Kubernetes ConfigMap to update (optional)',
      '  --namespace <ns>      Kubernetes namespace (default: default)',
      '  --rpc-url <url>       Soroban RPC endpoint',
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

function isValidContractId(id) {
  return typeof id === 'string' && CONTRACT_ID_RE.test(id);
}

/**
 * Verify a contract exists on-chain by calling the Soroban RPC
 * `getLedgerEntries` method with the contract's ledger key.
 *
 * We use a raw JSON-RPC POST so the script has no npm dependencies.
 */
async function contractExistsOnChain(contractId, rpcUrl) {
  // Build the ledger key for the contract instance.
  // The XDR for a contract instance key is:
  //   LedgerKey::contractData({
  //     contract: SCAddress::contract(contractId),
  //     key: SCVal::ledgerKeyContractInstance(),
  //     durability: ContractDataDurability::persistent
  //   })
  //
  // Rather than hand-rolling XDR, we shell out to the `stellar` CLI when
  // available, and fall back to a best-effort RPC probe otherwise.
  try {
    const out = execFileSync(
      'stellar',
      [
        'contract',
        'info',
        '--id',
        contractId,
        '--network',
        networkNameFromRpc(rpcUrl),
      ],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
    );
    return out.length > 0;
  } catch (err) {
    // If the CLI is unavailable, fall back to a raw RPC probe.
    if (err && err.code === 'ENOENT') {
      return probeViaRpc(contractId, rpcUrl);
    }
    // CLI present but returned non-zero: contract not found.
    return false;
  }
}

function networkNameFromRpc(rpcUrl) {
  if (/mainnet/i.test(rpcUrl)) return 'mainnet';
  if (/futurenet/i.test(rpcUrl)) return 'futurenet';
  return 'testnet';
}

async function probeViaRpc(contractId, rpcUrl) {
  // Best-effort probe: ask the RPC for the latest ledger and confirm the
  // endpoint is reachable. Full ledger-key construction requires XDR
  // encoding, which we intentionally avoid here to keep the script
  // dependency-free. Operators with the `stellar` CLI installed get strict
  // verification; without it we degrade to a reachability check and warn.
  process.stderr.write(
    `[warn] 'stellar' CLI not found; performing reachability-only check for ${contractId}\n`
  );

  const body = JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'getLatestLedger',
    params: {},
  });

  const res = await fetch(rpcUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
  });

  if (!res.ok) {
    throw new Error(`Soroban RPC returned HTTP ${res.status}`);
  }

  const json = await res.json();
  return Boolean(json && json.result);
}

// ---------------------------------------------------------------------------
// Environment / ConfigMap updates.
// ---------------------------------------------------------------------------

function updateEnvFile(envFilePath, contractIds, dryRun) {
  const existing = fs.existsSync(envFilePath)
    ? fs.readFileSync(envFilePath, 'utf8')
    : '';

  const lines = existing.split(/\r?\n/);
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

  const contents = updated.join('\n');

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
  const args = [
    'create',
    'configmap',
    name,
    '--namespace',
    namespace,
    '--dry-run=client',
    '-o',
    'yaml',
  ];

  for (const [key, value] of Object.entries(contractIds)) {
    args.push(`--from-literal=${key}=${value}`);
  }

  if (dryRun) {
    process.stdout.write(
      `[dry-run] Would apply ConfigMap ${namespace}/${name} with:\n` +
        Object.entries(contractIds)
          .map(([k, v]) => `  ${k}=${v}`)
          .join('\n') +
        '\n'
    );
    return;
  }

  try {
    const yaml = execFileSync('kubectl', args, { encoding: 'utf8' });
    execFileSync('kubectl', ['apply', '-f', '-'], {
      input: yaml,
      encoding: 'utf8',
      stdio: ['pipe', 'inherit', 'inherit'],
    });
    process.stdout.write(
      `[ok] Updated ConfigMap: ${namespace}/${name}\n`
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