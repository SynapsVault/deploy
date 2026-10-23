'use strict';

// Unit tests for scripts/02-fund-accounts.js: the failure/exit-code
// contract, exercised end-to-end with fetch stubbed out (no network).
// Run with: npm test

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { pathToFileURL } = require('url');

const { Keypair } = require('@stellar/stellar-sdk');

const ROOT = path.resolve(__dirname, '..');
const SCRIPT = path.join(ROOT, 'scripts', '02-fund-accounts.js');
const FETCH_STUB = path.join(__dirname, 'friendbot-fetch-stub.mjs');

// A contract id (C...) is a valid StrKey, but not an ed25519 public key.
const CONTRACT_ID = 'CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA';

const FUNDED = { status: 200, json: { id: 'abc123tx', hash: 'def456hash' } };
const ALREADY_FUNDED = { status: 400, json: { detail: 'account already funded' } };

/**
 * Runs the script with globalThis.fetch replaced by the stub.
 * `scenario` selects what the stub answers (see friendbot-fetch-stub.mjs).
 * Returns the exit status, captured output and the URLs the stub saw.
 */
function runScript(args, scenario) {
  const log = path.join(
    os.tmpdir(),
    `friendbot-stub-${process.pid}-${Math.random().toString(36).slice(2)}.log`
  );

  let status = 0;
  let stdout = '';
  let stderr = '';
  try {
    stdout = execFileSync(
      process.execPath,
      ['--import', pathToFileURL(FETCH_STUB).href, SCRIPT, ...args],
      {
        env: { ...process.env, FRIENDBOT_STUB: JSON.stringify(scenario), FRIENDBOT_STUB_LOG: log },
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      }
    );
  } catch (err) {
    status = err.status ?? 1;
    stdout = err.stdout ?? '';
    stderr = err.stderr ?? '';
  }

  let requested = [];
  try {
    requested = fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean);
  } catch {
    /* the stub was never called */
  }
  fs.rmSync(log, { force: true });

  return { status, stdout, stderr, requested };
}

test('funds every account and exits 0', () => {
  const keys = [Keypair.random().publicKey(), Keypair.random().publicKey()];
  const { status, stdout, requested } = runScript(keys, FUNDED);

  assert.equal(status, 0);
  assert.match(stdout, /Funding 2 account\(s\)/);
  assert.match(stdout, /✅ Funded/);
  assert.match(stdout, /tx: abc123tx/);
  assert.match(stdout, /Next →/);
  assert.equal(requested.length, 2);
  for (const key of keys) {
    assert.ok(
      requested.some((url) => url.includes(`addr=${key}`)),
      `funded ${key}`
    );
  }
});

test('treats an already-funded account as success', () => {
  const { status, stdout } = runScript([Keypair.random().publicKey()], ALREADY_FUNDED);

  assert.equal(status, 0);
  assert.match(stdout, /already funded/);
  assert.doesNotMatch(stdout, /❌/);
});

test('survives a non-JSON error body and exits non-zero', () => {
  const { status, stderr } = runScript([Keypair.random().publicKey()], {
    status: 502,
    text: '<html><body>502 Bad Gateway</body></html>',
  });

  assert.equal(status, 1);
  assert.match(stderr, /❌ Failed/);
  assert.match(stderr, /1 of 1 account\(s\) could not be funded/);
});

test('exits non-zero when the request itself fails', () => {
  const { status, stderr } = runScript([Keypair.random().publicKey()], {
    throw: 'getaddrinfo ENOTFOUND friendbot.stellar.org',
  });

  assert.equal(status, 1);
  assert.match(stderr, /ENOTFOUND/);
});

test('exits non-zero when one of several accounts fails', () => {
  const keys = [Keypair.random().publicKey(), Keypair.random().publicKey()];
  const { status, stdout, stderr } = runScript(keys, [
    FUNDED,
    { status: 400, json: { detail: 'friendbot is overloaded' } },
  ]);

  assert.equal(status, 1);
  assert.match(stdout, /✅ Funded/);
  assert.match(stderr, /friendbot is overloaded/);
  assert.match(stderr, /1 of 2 account\(s\) could not be funded/);
});

test('rejects invalid keys before contacting Friendbot', () => {
  const { status, stderr, requested } = runScript(
    [Keypair.random().publicKey(), 'not-a-key', CONTRACT_ID],
    FUNDED
  );

  assert.equal(status, 1);
  assert.match(stderr, /Not valid ed25519 public keys: not-a-key, CBIELTK/);
  assert.deepEqual(requested, []);
});

test('prints usage and exits non-zero without keys', () => {
  const { status, stderr, requested } = runScript([], FUNDED);

  assert.equal(status, 1);
  assert.match(stderr, /Usage: node scripts\/02-fund-accounts\.js/);
  assert.deepEqual(requested, []);
});
