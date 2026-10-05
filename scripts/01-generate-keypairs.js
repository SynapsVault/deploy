/**
 * SynapsVault — Step 1: Generate Keypairs
 *
 * Generates 5 Stellar keypairs for testnet deployment:
 * - DEPLOYER: Contract deployment authority
 * - BACKEND: Platform wallet for signing transactions
 * - PUBLISHER1/2: Test publisher accounts
 * - BUYER1: Test buyer account
 *
 * ⚠️  IMPORTANT: Save output in a password manager immediately!
 * Store securely—never commit to git.
 *
 * Usage:
 *   node scripts/01-generate-keypairs.js
 */
import { Keypair } from "@stellar/stellar-sdk";

function gen(label) {
  try {
    const kp = Keypair.random();
    return { label, pub: kp.publicKey(), sec: kp.secret() };
  } catch (error) {
    console.error(`❌ Error generating keypair: ${error.message}`);
    process.exit(1);
  }
}

const wallets = [
  gen("DEPLOYER   (deploys contracts + holds admin role)"),
  gen("BACKEND    (platform wallet — signs lease grants)"),
  gen("PUBLISHER1 (test publisher #1)"),
  gen("PUBLISHER2 (test publisher #2)"),
  gen("BUYER1     (test buyer wallet)"),
];

console.log("\n╔══════════════════════════════════════════════════════╗");
console.log("║   SynapsVault Testnet Keypairs — SAVE THESE NOW      ║");
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
