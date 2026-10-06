'use strict';

// Unit tests for the offline parts of the contract deploy/rollback scripts.
// Run with: npm test

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Keypair } = require('@stellar/stellar-sdk');

const rollback = require('../scripts/rollback-contracts.cjs');
const deploy = require('../scripts/deploy-contracts.cjs');

const VALID_ID = 'CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA';

function withEnv(vars, fn) {
  const saved = {};
  for (const [k, v] of Object.entries(vars)) {
    saved[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test('parseEnvFile handles comments, blanks, quotes and CRLF', () => {
  const parsed = rollback.parseEnvFile(
    '# header\r\n\r\nA=1\r\nB="two"\nC=\'three\'\nnot-a-pair\nD = spaced \n'
  );
  assert.deepEqual(parsed, { A: '1', B: 'two', C: 'three', D: 'spaced' });
});

test('isValidContractId accepts C-addresses only', () => {
  assert.equal(rollback.isValidContractId(VALID_ID), true);
  assert.equal(rollback.isValidContractId(VALID_ID.slice(1)), false);
  assert.equal(rollback.isValidContractId('G' + VALID_ID.slice(1)), false);
  assert.equal(rollback.isValidContractId(undefined), false);
});

test('rollback parseArgs requires --backup and resolves default RPC per network', () => {
  assert.throws(() => rollback.parseArgs([]), /--backup/);

  const args = withEnv({ SOROBAN_RPC_URL: undefined, STELLAR_NETWORK: undefined }, () =>
    rollback.parseArgs(['--backup', 'b.env', '--target-env', 'x.env', '--dry-run'])
  );
  assert.equal(args.backup, 'b.env');
  assert.equal(args.envFile, 'x.env');
  assert.equal(args.namespace, 'synapsvault');
  assert.equal(args.rpcUrl, 'https://soroban-testnet.stellar.org');
  assert.equal(args.dryRun, true);

  assert.throws(
    () =>
      withEnv({ SOROBAN_RPC_URL: undefined }, () =>
        rollback.parseArgs(['--backup', 'b.env', '--network', 'mainnet'])
      ),
    /--rpc-url/
  );
});

test('updateEnvFile replaces existing keys, appends new ones, keeps other lines', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rollback-test-'));
  const file = path.join(dir, '.env');
  fs.writeFileSync(file, '# keep me\nOTHER=x\nVAULT_REGISTRY_CONTRACT_ID=old\n');

  const silence = process.stdout.write;
  process.stdout.write = () => true;
  try {
    rollback.updateEnvFile(
      file,
      { VAULT_REGISTRY_CONTRACT_ID: VALID_ID, ACCESS_LEASE_CONTRACT_ID: VALID_ID },
      false
    );
  } finally {
    process.stdout.write = silence;
  }

  assert.equal(
    fs.readFileSync(file, 'utf8'),
    `# keep me\nOTHER=x\nVAULT_REGISTRY_CONTRACT_ID=${VALID_ID}\nACCESS_LEASE_CONTRACT_ID=${VALID_ID}\n`
  );
  fs.rmSync(dir, { recursive: true, force: true });
});

test('deploy parseArgs understands --network, --wasm-dir, --yes, --dry-run', () => {
  const args = deploy.parseArgs(['--network=testnet', '--wasm-dir', '/w', '--yes', '--dry-run']);
  assert.deepEqual(args, { network: 'testnet', wasmDir: '/w', yes: true, dryRun: true });
  assert.throws(() => deploy.parseArgs(['--network', 'moonnet']), /Invalid --network/);
  assert.throws(() => deploy.parseArgs(['--bogus']), /Unknown argument/);
});

test('deploy validateEnv resolves RPC, admin and wasm paths', () => {
  const kp = Keypair.random();
  const admin = Keypair.random().publicKey();

  const cfg = withEnv(
    {
      STELLAR_SECRET_KEY: kp.secret(),
      NETWORK: 'testnet',
      SOROBAN_RPC_URL: undefined,
      CONTRACTS_WASM_DIR: '/wasm',
      ADMIN_PUBLIC_KEY: admin,
    },
    () => deploy.validateEnv(deploy.parseArgs([]))
  );
  assert.equal(cfg.rpcUrl, 'https://soroban-testnet.stellar.org');
  assert.equal(cfg.adminAddress, admin);
  assert.deepEqual(
    cfg.contracts.map((c) => c.wasm),
    ['/wasm/vault_registry.wasm', '/wasm/access_lease.wasm', '/wasm/subscription.wasm']
  );

  // Mainnet has no default RPC URL.
  assert.throws(
    () =>
      withEnv({ STELLAR_SECRET_KEY: kp.secret(), NETWORK: 'mainnet', SOROBAN_RPC_URL: undefined }, () =>
        deploy.validateEnv(deploy.parseArgs([]))
      ),
    /SOROBAN_RPC_URL/
  );

  // Defaults the admin to the deployer.
  const self = withEnv(
    { STELLAR_SECRET_KEY: kp.secret(), NETWORK: 'testnet', ADMIN_PUBLIC_KEY: undefined },
    () => deploy.validateEnv(deploy.parseArgs([]))
  );
  assert.equal(self.adminAddress, kp.publicKey());
});
