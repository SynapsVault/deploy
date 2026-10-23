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

test('canonicalContractKey normalises every deploy-path spelling', () => {
  assert.equal(
    rollback.canonicalContractKey('STELLAR_CONTRACT_VAULT_REGISTRY', 'x'),
    'STELLAR_CONTRACT_VAULT_REGISTRY'
  );
  assert.equal(
    rollback.canonicalContractKey('VAULT_REGISTRY_CONTRACT_ID', 'x'),
    'STELLAR_CONTRACT_VAULT_REGISTRY'
  );
  assert.equal(
    rollback.canonicalContractKey('ACCESS_LEASE_CONTRACT', 'x'),
    'STELLAR_CONTRACT_ACCESS_LEASE'
  );
  assert.equal(
    rollback.canonicalContractKey('REGISTRY_CONTRACT_ID', 'x'),
    'STELLAR_CONTRACT_VAULT_REGISTRY'
  );
  assert.equal(
    rollback.canonicalContractKey('vault_registry', VALID_ID),
    'STELLAR_CONTRACT_VAULT_REGISTRY'
  );
  // Bare names are only contract references when the value is a contract ID.
  assert.equal(rollback.canonicalContractKey('network', 'testnet'), null);
  assert.equal(rollback.canonicalContractKey('NETWORK', 'testnet'), null);
});

test('deploy contractEnvName uses the canonical STELLAR_CONTRACT_* scheme', () => {
  assert.equal(deploy.contractEnvName('vault-registry'), 'STELLAR_CONTRACT_VAULT_REGISTRY');
  assert.equal(deploy.contractEnvName('access-lease'), 'STELLAR_CONTRACT_ACCESS_LEASE');
  assert.equal(deploy.contractEnvName('subscription'), 'STELLAR_CONTRACT_SUBSCRIPTION');
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

test('updateEnvFile updates aliases, appends canonical keys, keeps other lines', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rollback-test-'));
  const file = path.join(dir, '.env');
  fs.writeFileSync(file, '# keep me\nOTHER=x\nVAULT_REGISTRY_CONTRACT_ID=old\n');

  const silence = process.stdout.write;
  process.stdout.write = () => true;
  try {
    rollback.updateEnvFile(
      file,
      { STELLAR_CONTRACT_VAULT_REGISTRY: VALID_ID, STELLAR_CONTRACT_ACCESS_LEASE: VALID_ID },
      false
    );
  } finally {
    process.stdout.write = silence;
  }

  // The legacy alias is kept in sync and the canonical key is appended.
  assert.equal(
    fs.readFileSync(file, 'utf8'),
    `# keep me\nOTHER=x\nVAULT_REGISTRY_CONTRACT_ID=${VALID_ID}\n` +
      `STELLAR_CONTRACT_VAULT_REGISTRY=${VALID_ID}\nSTELLAR_CONTRACT_ACCESS_LEASE=${VALID_ID}\n`
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
      withEnv(
        { STELLAR_SECRET_KEY: kp.secret(), NETWORK: 'mainnet', SOROBAN_RPC_URL: undefined },
        () => deploy.validateEnv(deploy.parseArgs([]))
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

test('deploy preflightChecks verifies balance and WASM files with a mocked RPC server', async () => {
  const kp = Keypair.random();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wasm-test-'));
  const contracts = deploy.CONTRACTS.map((c) => {
    const wasmPath = path.join(dir, c.wasmFile);
    fs.writeFileSync(wasmPath, Buffer.from([0x00, 0x61, 0x73, 0x6d]));
    return { ...c, wasm: wasmPath };
  });

  const mockServer = {
    getAccountEntry: async () => ({ balance: () => '250000000' }), // 25 XLM
  };

  await deploy.preflightChecks({
    server: mockServer,
    keypair: kp,
    network: 'testnet',
    contracts,
    dryRun: true,
  });

  // Low balance should fail preflight
  const lowBalanceServer = {
    getAccountEntry: async () => ({ balance: '1000000' }), // 0.1 XLM
  };
  await assert.rejects(
    () =>
      deploy.preflightChecks({
        server: lowBalanceServer,
        keypair: kp,
        network: 'testnet',
        contracts,
        dryRun: false,
      }),
    /Insufficient balance/
  );

  fs.rmSync(dir, { recursive: true, force: true });
});

test('deploy submitTransaction and pollTransaction handle mocked RPC responses', async () => {
  const kp = Keypair.random();
  let signed = false;
  let pollCalls = 0;

  const mockTx = {};
  const mockServer = {
    prepareTransaction: async () => ({
      sign: () => {
        signed = true;
      },
    }),
    sendTransaction: async () => ({ status: 'PENDING', hash: 'txhash123' }),
    getTransaction: async (hash) => {
      assert.equal(hash, 'txhash123');
      pollCalls += 1;
      if (pollCalls === 1) return { status: 'NOT_FOUND' };
      return { status: 'SUCCESS', hash };
    },
  };

  const res = await deploy.submitTransaction({
    server: mockServer,
    tx: mockTx,
    keypair: kp,
    networkPassphrase: 'Test SDF Network ; September 2015',
    dryRun: false,
    label: 'unit-test-tx',
  });

  assert.equal(signed, true);
  assert.equal(res.status, 'SUCCESS');
  assert.ok(pollCalls >= 2);

  // Dry run skips RPC calls entirely
  const dryRes = await deploy.submitTransaction({
    server: {},
    tx: mockTx,
    keypair: kp,
    networkPassphrase: 'Test SDF Network ; September 2015',
    dryRun: true,
    label: 'dry-run-tx',
  });
  assert.equal(dryRes, null);
});

test('deployment resume rejects contract IDs from another network', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'resume-test-'));
  const file = path.join(dir, 'ids.env');
  try {
    fs.writeFileSync(file, `# Network: testnet\nSTELLAR_CONTRACT_VAULT_REGISTRY=${VALID_ID}\n`);
    assert.throws(
      () => deploy.loadExistingContractIds('mainnet', file),
      /different or unknown network/
    );
    assert.deepEqual(deploy.loadExistingContractIds('testnet', file), {
      'vault-registry': VALID_ID,
    });
    fs.writeFileSync(file, '# Network: testnet\nSTELLAR_CONTRACT_VAULT_REGISTRY=invalid\n');
    assert.throws(() => deploy.loadExistingContractIds('testnet', file), /Invalid saved contract/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('contract verification rejects an unexpected on-chain admin', async () => {
  const { nativeToScVal } = require('@stellar/stellar-sdk');
  const server = {
    getContractData: async () => ({
      val: {
        value: {
          val: {
            value: {
              storage: [
                {
                  key: nativeToScVal('admin', { type: 'symbol' }),
                  val: nativeToScVal('wrong-admin'),
                },
              ],
            },
          },
        },
      },
    }),
  };
  await assert.rejects(
    () =>
      deploy.verifyContract({
        server,
        contractId: VALID_ID,
        contractName: 'test-contract',
        expectedAdmin: 'expected-admin',
      }),
    /admin mismatch/
  );
});
