/**
 * SynapsVault — Step 2: Fund testnet accounts via Friendbot
 *
 * Usage:
 *   node scripts/02-fund-accounts.js G... G... G...
 *   (pass as many public keys as you like)
 *
 * Friendbot gives each account 10,000 XLM on testnet — free.
 */

const FRIENDBOT = "https://friendbot.stellar.org";

async function fund(publicKey) {
  const url = `${FRIENDBOT}?addr=${encodeURIComponent(publicKey)}`;
  const res  = await fetch(url);
  const body = await res.json();

  if (res.ok) {
    console.log(`✅ Funded ${publicKey.slice(0, 10)}…  tx: ${body.id ?? body.hash}`);
  } else {
    console.error(`❌ Failed ${publicKey.slice(0, 10)}…  ${body.detail ?? JSON.stringify(body)}`);
  }
}

const keys = process.argv.slice(2);
if (keys.length === 0) {
  console.error("Usage: node scripts/02-fund-accounts.js G... G... G...");
  process.exit(1);
}

console.log(`\nFunding ${keys.length} account(s) on Stellar testnet…\n`);
for (const k of keys) await fund(k);
console.log("\nNext → build + deploy contracts:");
console.log("  node scripts/03-deploy-contracts.js\n");
