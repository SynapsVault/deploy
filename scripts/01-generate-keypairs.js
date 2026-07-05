/**
 * AtriumMind — Step 1: Generate Keypairs
 * Run ONCE locally. Save output in a password manager.
 *
 * Usage:
 *   npm install @stellar/stellar-sdk
 *   node scripts/01-generate-keypairs.js
 */
import { Keypair } from "@stellar/stellar-sdk";

function gen(label) {
  const kp = Keypair.random();
  return { label, pub: kp.publicKey(), sec: kp.secret() };
}

const wallets = [
  gen("DEPLOYER   (deploys contracts + holds admin role)"),
  gen("BACKEND    (platform wallet — signs lease grants)"),
  gen("PUBLISHER1 (test publisher #1)"),
  gen("PUBLISHER2 (test publisher #2)"),
  gen("BUYER1     (test buyer wallet)"),
];

console.log("\n╔══════════════════════════════════════════════════════╗");
console.log("║   AtriumMind Testnet Keypairs — SAVE THESE NOW      ║");
console.log("╚══════════════════════════════════════════════════════╝\n");

for (const w of wallets) {
  console.log(`▸ ${w.label}`);
  console.log(`  Public : ${w.pub}`);
  console.log(`  Secret : ${w.sec}\n`);
}

console.log("═".repeat(56));
console.log("Next → fund each account:");
console.log("  node scripts/02-fund-accounts.js");
console.log("  (or use https://laboratory.stellar.org/#account-creator?network=test)\n");
