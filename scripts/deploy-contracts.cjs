#!/usr/bin/env node
'use strict';

/**
 * Automated Soroban contract deployment script.
 *
 * Deploys the vault-registry, access-lease, and subscription contracts to a
 * Soroban network, initializes each with the admin key, writes the resulting
 * contract IDs to contract-ids.env, and verifies each contract on-chain.
 *
 * Usage:
 *   node scripts/deploy-contracts.cjs [--network testnet|mainnet] [--wasm-dir <dir>] [--yes] [--dry-run]
 *
 * Required environment variables:
 *   STELLAR_SECRET_KEY  - Secret key of the deploying account.
 *   NETWORK             - Target network (testnet|mainnet). Overridden by --network.
 *
 * Optional environment variables:
 *   SOROBAN_RPC_URL     - Soroban RPC endpoint (defaults to the public testnet
 *                         RPC for testnet; required for mainnet).
 *   CONTRACTS_WASM_DIR  - Directory containing the built *.wasm files. Overridden
 *                         by --wasm-dir. Defaults to ./target/wasm32-unknown-unknown/release.
 *   ADMIN_PUBLIC_KEY    - Address passed to each contract's init(admin). Defaults
 *                         to the deployer's public key.
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const {
  Keypair,
  Networks,
  Contract,
  TransactionBuilder,
  Operation,
  Address,
  nativeToScVal,
  scValToNative,
  rpc,
  xdr,
  StrKey,
} = require('@stellar/stellar-sdk');

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const ROOT_DIR = path.resolve(__dirname, '..');
const CONTRACT_IDS_FILE = path.join(ROOT_DIR, 'contract-ids.env');

const NETWORK_PASSPHRASES = {
  testnet: Networks.TESTNET,
  mainnet: Networks.PUBLIC,
};

const DEFAULT_RPC_URLS = {
  testnet: 'https://soroban-testnet.stellar.org',
};

const DEFAULT_WASM_DIR = path.join(ROOT_DIR, 'target', 'wasm32-unknown-unknown', 'release');

// Each contract exposes `init(admin: Address)`.
const CONTRACTS = [
  { name: 'vault-registry', wasmFile: 'vault_registry.wasm' },
  { name: 'access-lease', wasmFile: 'access_lease.wasm' },
  { name: 'subscription', wasmFile: 'subscription.wasm' },
];

// Minimum account balance (in stroops) required to proceed with deployment.
const MIN_BALANCE_STROOPS = 10_000_000n; // 1 XLM

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { network: null, dryRun: false, yes: false, wasmDir: null };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--dry-run') {
      args.dryRun = true;
    } else if (arg === '--yes' || arg === '-y') {
      args.yes = true;
    } else if (arg === '--wasm-dir') {
      const value = argv[++i];
      if (!value) {
        throw new Error('--wasm-dir requires a value');
      }
      args.wasmDir = value;
    } else if (arg.startsWith('--wasm-dir=')) {
      args.wasmDir = arg.slice('--wasm-dir='.length);
    } else if (arg === '--network') {
      const value = argv[++i];
      if (!value) {
        throw new Error('--network requires a value (testnet|mainnet)');
      }
      args.network = value;
    } else if (arg.startsWith('--network=')) {
      args.network = arg.slice('--network='.length);
    } else if (arg === '--help' || arg === '-h') {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (args.network && !NETWORK_PASSPHRASES[args.network]) {
    throw new Error(`Invalid --network value: ${args.network} (expected testnet|mainnet)`);
  }

  return args;
}

function printUsage() {
  console.log(`Usage: node scripts/deploy-contracts.cjs [options]

Options:
  --network <testnet|mainnet>  Target network (defaults to $NETWORK).
  --wasm-dir <dir>             Directory containing the built contract *.wasm files
                               (defaults to $CONTRACTS_WASM_DIR, then ./target/wasm32-unknown-unknown/release).
  --yes, -y                    Skip the interactive mainnet confirmation (for CI).
  --dry-run                    Perform all checks without submitting transactions.
  --help, -h                   Show this help message.
`);
}

// ---------------------------------------------------------------------------
// Logging helpers
// ---------------------------------------------------------------------------

const log = {
  info: (msg) => console.log(`[info]  ${msg}`),
  step: (msg) => console.log(`\n==> ${msg}`),
  ok: (msg) => console.log(`[ok]    ${msg}`),
  warn: (msg) => console.warn(`[warn]  ${msg}`),
  error: (msg) => console.error(`[error] ${msg}`),
};

// ---------------------------------------------------------------------------
// Environment validation
// ---------------------------------------------------------------------------

function validateEnv(args) {
  const missing = [];

  const secretKey = process.env.STELLAR_SECRET_KEY;
  if (!secretKey) {
    missing.push('STELLAR_SECRET_KEY');
  }

  const network = args.network || process.env.NETWORK;
  if (!network) {
    missing.push('NETWORK (or pass --network)');
  } else if (!NETWORK_PASSPHRASES[network]) {
    throw new Error(`Invalid NETWORK value: ${network} (expected testnet|mainnet)`);
  }

  const rpcUrl = process.env.SOROBAN_RPC_URL || DEFAULT_RPC_URLS[network];
  if (!rpcUrl) {
    missing.push('SOROBAN_RPC_URL');
  }

  if (missing.length > 0) {
    throw new Error(`Missing required environment variables:\n  - ${missing.join('\n  - ')}`);
  }

  let keypair;
  try {
    keypair = Keypair.fromSecret(secretKey);
  } catch (err) {
    throw new Error(`STELLAR_SECRET_KEY is not a valid Stellar secret key: ${err.message}`);
  }

  const adminAddress = process.env.ADMIN_PUBLIC_KEY || keypair.publicKey();
  if (!StrKey.isValidEd25519PublicKey(adminAddress)) {
    throw new Error(`ADMIN_PUBLIC_KEY is not a valid Stellar public key: ${adminAddress}`);
  }

  const wasmDir = path.resolve(args.wasmDir || process.env.CONTRACTS_WASM_DIR || DEFAULT_WASM_DIR);
  const contracts = CONTRACTS.map((c) => ({ ...c, wasm: path.join(wasmDir, c.wasmFile) }));

  return { keypair, network, rpcUrl, adminAddress, contracts };
}

// ---------------------------------------------------------------------------
// Mainnet confirmation prompt
// ---------------------------------------------------------------------------

function confirmMainnet(network, assumeYes) {
  if (network !== 'mainnet' || assumeYes) {
    return Promise.resolve(true);
  }

  if (!process.stdin.isTTY) {
    log.error('Refusing to deploy to mainnet non-interactively without --yes.');
    return Promise.resolve(false);
  }

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question(
      '\n*** WARNING: You are about to deploy to MAINNET. ***\n' +
        'Type "deploy mainnet" to confirm: ',
      (answer) => {
        rl.close();
        resolve(answer.trim() === 'deploy mainnet');
      }
    );
  });
}

// ---------------------------------------------------------------------------
// Pre-flight checks
// ---------------------------------------------------------------------------

async function preflightChecks({ server, keypair, network, contracts, dryRun }) {
  log.step('Running pre-flight checks');

  // 1. Network passphrase sanity check.
  const networkPassphrase = NETWORK_PASSPHRASES[network];
  if (!networkPassphrase) {
    throw new Error(`No network passphrase configured for "${network}"`);
  }
  log.ok(`Network passphrase resolved for "${network}"`);

  // 2. Account existence and balance.
  const publicKey = keypair.publicKey();
  log.info(`Deployer account: ${publicKey}`);

  // Soroban RPC's getAccount() returns a bare Account (sequence only), so read
  // the full ledger entry to get the native balance.
  let accountEntry;
  try {
    accountEntry = await server.getAccountEntry(publicKey);
  } catch (err) {
    throw new Error(
      `Unable to load deployer account ${publicKey} from Soroban RPC. ` +
        `Ensure the account is funded on ${network}. (${err.message})`
    );
  }

  // Older SDKs expose XDR fields as accessor methods; v17+ as plain properties.
  const rawBalance =
    typeof accountEntry.balance === 'function' ? accountEntry.balance() : accountEntry.balance;
  const balanceStroops = BigInt(rawBalance.toString());
  const balanceXlm = (Number(balanceStroops) / 1e7).toFixed(7);
  log.info(`Native balance: ${balanceXlm} XLM`);

  if (balanceStroops < MIN_BALANCE_STROOPS) {
    throw new Error(
      `Insufficient balance: ${balanceXlm} XLM. ` +
        `At least ${Number(MIN_BALANCE_STROOPS) / 1e7} XLM is required.`
    );
  }
  log.ok('Account balance is sufficient');

  // 3. Contract WASM existence.
  for (const contract of contracts) {
    if (!fs.existsSync(contract.wasm)) {
      throw new Error(
        `WASM file not found for "${contract.name}": ${contract.wasm}\n` +
          'Build the contracts first (e.g. `cargo build --target wasm32-unknown-unknown --release`).'
      );
    }
    const size = fs.statSync(contract.wasm).size;
    log.ok(`Found WASM for "${contract.name}" (${size} bytes)`);
  }

  if (dryRun) {
    log.warn('Dry run enabled: no transactions will be submitted.');
  }

}

// ---------------------------------------------------------------------------
// Transaction helpers
// ---------------------------------------------------------------------------

async function submitTransaction({ server, tx, keypair, networkPassphrase, dryRun, label }) {
  if (dryRun) {
    log.info(`[dry-run] Skipping submission: ${label}`);
    return null;
  }

  const prepared = await server.prepareTransaction(tx);
  prepared.sign(keypair);

  const sendResponse = await server.sendTransaction(prepared);
  if (sendResponse.status === 'ERROR') {
    throw new Error(
      `Transaction submission failed for ${label}: ${JSON.stringify(sendResponse.errorResult || sendResponse)}`
    );
  }

  const hash = sendResponse.hash;
  log.info(`Submitted ${label} (hash: ${hash}); awaiting confirmation...`);

  const result = await pollTransaction(server, hash);
  if (result.status !== 'SUCCESS') {
    throw new Error(`Transaction ${hash} for ${label} did not succeed: ${result.status}`);
  }

  log.ok(`Confirmed ${label} (hash: ${hash})`);
  return result;
}

async function pollTransaction(server, hash, { attempts = 30, intervalMs = 2000 } = {}) {
  for (let i = 0; i < attempts; i++) {
    const response = await server.getTransaction(hash);
    if (response.status !== 'NOT_FOUND') {
      return response;
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  throw new Error(`Timed out waiting for transaction ${hash}`);
}

// ---------------------------------------------------------------------------
// WASM upload
// ---------------------------------------------------------------------------

async function uploadWasm({ server, keypair, networkPassphrase, wasmPath, dryRun, contractName }) {
  log.step(`Uploading WASM for "${contractName}"`);

  const wasm = fs.readFileSync(wasmPath);

  if (dryRun) {
    log.info(`[dry-run] Would upload ${wasm.length} bytes for "${contractName}"`);
    return 'DRY_RUN_WASM_HASH';
  }

  const account = await server.getAccount(keypair.publicKey());
  const tx = new TransactionBuilder(account, {
    fee: '1000000',
    networkPassphrase,
  })
    .addOperation(
      Operation.uploadContractWasm({
        wasm,
      })
    )
    .setTimeout(180)
    .build();

  const result = await submitTransaction({
    server,
    tx,
    keypair,
    networkPassphrase,
    dryRun,
    label: `upload WASM for "${contractName}"`,
  });

  const wasmHash = result.returnValue
    ? Buffer.from(scValToNative(result.returnValue)).toString('hex')
    : null;

  if (!wasmHash) {
    throw new Error(`Could not determine WASM hash for "${contractName}"`);
  }

  log.ok(`WASM hash for "${contractName}": ${wasmHash}`);
  return wasmHash;
}

// ---------------------------------------------------------------------------
// Contract deployment
// ---------------------------------------------------------------------------

async function deployContract({ server, keypair, networkPassphrase, wasmHash, dryRun, contractName }) {
  log.step(`Deploying contract "${contractName}"`);

  if (dryRun) {
    log.info(`[dry-run] Would deploy "${contractName}" from WASM hash ${wasmHash}`);
    return `DRY_RUN_${contractName.toUpperCase().replace(/-/g, '_')}_ID`;
  }

  const account = await server.getAccount(keypair.publicKey());
  const tx = new TransactionBuilder(account, {
    fee: '1000000',
    networkPassphrase,
  })
    .addOperation(
      Operation.createCustomContract({
        address: Address.fromString(keypair.publicKey()),
        wasmHash: Buffer.from(wasmHash, 'hex'),
      })
    )
    .setTimeout(180)
    .build();

  const result = await submitTransaction({
    server,
    tx,
    keypair,
    networkPassphrase,
    dryRun,
    label: `deploy "${contractName}"`,
  });

  const contractId = scValToNative(result.returnValue);
  if (!contractId || !StrKey.isValidContract(contractId)) {
    throw new Error(`Invalid contract ID returned for "${contractName}": ${contractId}`);
  }

  log.ok(`Deployed "${contractName}" at ${contractId}`);
  return contractId;
}

// ---------------------------------------------------------------------------
// Contract initialization
// ---------------------------------------------------------------------------

async function initContract({ server, keypair, networkPassphrase, contractId, adminAddress, dryRun, contractName }) {
  log.step(`Initializing contract "${contractName}"`);

  if (dryRun) {
    log.info(`[dry-run] Would call init(${adminAddress}) on "${contractName}"`);
    return;
  }

  const contract = new Contract(contractId);
  const account = await server.getAccount(keypair.publicKey());

  const tx = new TransactionBuilder(account, {
    fee: '1000000',
    networkPassphrase,
  })
    .addOperation(
      contract.call('init', Address.fromString(adminAddress).toScVal())
    )
    .setTimeout(180)
    .build();

  await submitTransaction({
    server,
    tx,
    keypair,
    networkPassphrase,
    dryRun,
    label: `init "${contractName}"`,
  });

  log.ok(`Initialized "${contractName}" with admin ${adminAddress}`);
}

// ---------------------------------------------------------------------------
// On-chain verification
// ---------------------------------------------------------------------------

async function verifyContract({ server, contractId, dryRun, contractName }) {
  log.step(`Verifying contract "${contractName}"`);

  if (dryRun) {
    log.info(`[dry-run] Would verify "${contractName}" at ${contractId}`);
    return;
  }

  const ledgerEntries = await server.getContractData(
    contractId,
    xdr.ScVal.scvLedgerKeyContractInstance(),
    rpc.Durability.Persistent
  );

  if (!ledgerEntries || !ledgerEntries.val) {
    throw new Error(`Contract "${contractName}" (${contractId}) not found on-chain`);
  }

  log.ok(`Verified "${contractName}" exists on-chain at ${contractId}`);
}

// ---------------------------------------------------------------------------
// Output file
// ---------------------------------------------------------------------------

function writeContractIds(contractIds, network, dryRun) {
  log.step('Writing contract IDs');

  const lines = [
    `# Generated by scripts/deploy-contracts.cjs on ${new Date().toISOString()}`,
    `# Network: ${network}`,
    '',
  ];

  for (const [name, id] of Object.entries(contractIds)) {
    const envName = `${name.toUpperCase().replace(/-/g, '_')}_CONTRACT_ID`;
    lines.push(`${envName}=${id}`);
  }

  const content = lines.join('\n') + '\n';

  if (dryRun) {
    log.info('[dry-run] Would write the following to contract-ids.env:');
    console.log(content);
    return;
  }

  fs.writeFileSync(CONTRACT_IDS_FILE, content, { encoding: 'utf8' });
  log.ok(`Wrote contract IDs to ${CONTRACT_IDS_FILE}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));

  const { keypair, network, rpcUrl, adminAddress, contracts } = validateEnv(args);
  const networkPassphrase = NETWORK_PASSPHRASES[network];

  log.info(`Target network: ${network}`);
  log.info(`Soroban RPC URL: ${rpcUrl}`);
  if (args.dryRun) {
    log.warn('Running in DRY-RUN mode');
  }

  const confirmed = await confirmMainnet(network, args.yes);
  if (!confirmed) {
    log.error('Mainnet deployment not confirmed. Aborting.');
    process.exit(1);
  }

  const server = new rpc.Server(rpcUrl, { allowHttp: rpcUrl.startsWith('http://') });

  await preflightChecks({ server, keypair, network, contracts, dryRun: args.dryRun });

  log.info(`Admin address for init(): ${adminAddress}`);
  const contractIds = {};

  for (const contract of contracts) {
    const wasmHash = await uploadWasm({
      server,
      keypair,
      networkPassphrase,
      wasmPath: contract.wasm,
      dryRun: args.dryRun,
      contractName: contract.name,
    });

    const contractId = await deployContract({
      server,
      keypair,
      networkPassphrase,
      wasmHash,
      dryRun: args.dryRun,
      contractName: contract.name,
    });

    await initContract({
      server,
      keypair,
      networkPassphrase,
      contractId,
      adminAddress,
      dryRun: args.dryRun,
      contractName: contract.name,
    });

    await verifyContract({
      server,
      contractId,
      dryRun: args.dryRun,
      contractName: contract.name,
    });

    contractIds[contract.name] = contractId;
  }

  writeContractIds(contractIds, network, args.dryRun);

  log.step('Deployment complete');
  for (const [name, id] of Object.entries(contractIds)) {
    log.ok(`${name}: ${id}`);
  }
}

if (require.main === module) {
  main().catch((err) => {
    log.error(err.message || String(err));
    if (process.env.DEBUG) {
      console.error(err.stack);
    }
    process.exit(1);
  });
}

module.exports = { parseArgs, validateEnv, CONTRACTS };