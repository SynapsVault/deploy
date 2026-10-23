/**
 * SynapsVault — Step 1: Generate Keypairs
 *
 * Generates 5 Stellar keypairs for testnet deployment:
 * - DEPLOYER: Contract deployment authority
 * - BACKEND: Platform wallet for signing transactions
 * - PUBLISHER1/2: Test publisher accounts
 * - BUYER1: Test buyer account
 *
 * ⚠️  IMPORTANT: Save output securely!
 * Never commit keypairs to git. Use --output to write to a protected file.
 *
 * Usage:
 *   node scripts/01-generate-keypairs.js [--output <file>]
 *
 * Options:
 *   --output <file>  Write keypairs to file (mode 0600) instead of stdout
 *                    Prevents secrets from appearing in CI logs
 */
import { Keypair } from "@stellar/stellar-sdk";
import fs from "fs";
import path from "path";

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

function formatOutput(wallets) {
  const lines = [];
  lines.push("\n╔══════════════════════════════════════════════════════╗");
  lines.push("║   SynapsVault Testnet Keypairs — SAVE THESE NOW      ║");
  lines.push("╚══════════════════════════════════════════════════════╝\n");

  for (const w of wallets) {
    lines.push(`▸ ${w.label}`);
    lines.push(`  Public : ${w.pub}`);
    lines.push(`  Secret : ${w.sec}\n`);
  }

  lines.push("═".repeat(56));
  lines.push("Next → fund each account:");
  lines.push("  node scripts/02-fund-accounts.js");
  lines.push("  (or use https://laboratory.stellar.org/#account-creator?network=test)\n");

  return lines.join("\n");
}

// Parse command-line arguments
let outputFile = null;
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === "--output" || process.argv[i] === "-o") {
    if (i + 1 >= process.argv.length) {
      console.error("❌ --output requires a file path");
      process.exit(1);
    }
    outputFile = process.argv[++i];
  }
}

const output = formatOutput(wallets);

if (outputFile) {
  // Write to file with restricted permissions (mode 0600: rw-------)
  // This prevents the secrets from being readable by other users or appearing in CI logs
  try {
    fs.writeFileSync(outputFile, output, { mode: 0o600, flag: "wx" });
    console.log(`✅ Keypairs written to: ${path.resolve(outputFile)}`);
    console.log(`⚠️  File permissions set to 0600 (owner read/write only)`);
    console.log(`📋 Import the keypairs manually into your secure password manager.\n`);
  } catch (error) {
    console.error(`❌ Failed to write to ${outputFile}: ${error.message}`);
    process.exit(1);
  }
} else {
  // Print to stdout (for manual use, not CI)
  console.log("⚠️  WARNING: Outputting secrets to stdout!");
  console.log("   Use --output <file> to write securely to a file instead.\n");
  console.log(output);
}
