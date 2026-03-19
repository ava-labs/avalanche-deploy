#!/usr/bin/env node
/**
 * Patch @safe-global/safe-deployments to add a custom chain.
 * Run inside the safe-wallet-web container BEFORE 'yarn build'.
 *
 * Handles BOTH JSON format versions:
 *   V1 (old): { "defaultAddress": "0x...", "networkAddresses": { "1": "0x..." } }
 *   V2 (new): { "deployments": { "canonical": { "address": "0x..." } },
 *              "networkAddresses": { "1": "canonical" } }
 *
 * For V1: adds chainId -> defaultAddress
 * For V2: adds chainId -> "canonical" (the key in the deployments map)
 *
 * Usage: node patch-safe-deployments.js <chain_id>
 */

const fs = require('fs');
const path = require('path');

const chainId = process.argv[2];
if (!chainId || !/^\d+$/.test(chainId)) {
  console.error('Usage: node patch-safe-deployments.js <chain_id>');
  process.exit(1);
}

console.log(`\nPatching safe-deployments for chain ${chainId}...\n`);

// Find ALL copies of safe-deployments in the project tree.
// The protocol-kit packages (safe-core-sdk, safe-core-sdk-utils, safe-ethers-lib)
// each have their own nested copy that must also be patched.
const searchRoots = ['/app', process.cwd()];
const assetsDirs = [];

function findAssetsDirs(dir) {
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const full = path.join(dir, entry.name);
      if (full.endsWith('safe-deployments/dist/assets') || full.endsWith('safe-deployments/src/assets')) {
        assetsDirs.push(full);
      } else if (entry.name !== '.cache' && entry.name !== '.next') {
        findAssetsDirs(full);
      }
    }
  } catch (e) { /* permission errors, etc */ }
}

for (const root of searchRoots) {
  findAssetsDirs(root);
}

if (assetsDirs.length === 0) {
  console.error('ERROR: Could not find any safe-deployments assets directories');
  process.exit(1);
}

console.log(`Found ${assetsDirs.length} safe-deployments copies:`);
assetsDirs.forEach(d => console.log(`  ${d}`));
console.log('');

/**
 * Resolve the canonical address entry for a deployment JSON file.
 * Returns the value to insert into networkAddresses[chainId].
 *
 * V1 format: returns the defaultAddress string (e.g., "0x29fc...")
 * V2 format: returns the deployment type key (e.g., "canonical")
 *            which references deployments.canonical.address
 */
function resolveCanonicalEntry(data) {
  // V2 format: has "deployments" object with named entries like "canonical", "zksync"
  if (data.deployments && data.networkAddresses) {
    // Use whatever chain 1 (Ethereum mainnet) uses — it's always the canonical deployment
    const mainnetEntry = data.networkAddresses['1'];
    if (mainnetEntry) return mainnetEntry;

    // Fallback: first key in deployments (usually "canonical")
    const firstKey = Object.keys(data.deployments)[0];
    if (firstKey) return firstKey;
  }

  // V1 format: has "defaultAddress" as a flat hex string
  if (data.defaultAddress && data.networkAddresses) {
    return data.defaultAddress;
  }

  return null;
}

// Patch all contract versions in ALL copies
const versions = ['v1.3.0', 'v1.4.1'];
let totalPatched = 0;
let totalSkipped = 0;
let totalFailed = 0;

for (const assetsDir of assetsDirs) {
  for (const version of versions) {
    const versionDir = path.join(assetsDir, version);
    if (!fs.existsSync(versionDir)) continue;

    const files = fs.readdirSync(versionDir).filter(f => f.endsWith('.json'));
    let versionPatched = 0;

    for (const file of files) {
      const filePath = path.join(versionDir, file);
      try {
        const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));

        if (!data.networkAddresses) continue;

        // Already patched for this chain
        if (data.networkAddresses[chainId]) {
          totalSkipped++;
          continue;
        }

        const entry = resolveCanonicalEntry(data);
        if (!entry) {
          console.error(`  WARNING: ${file} - could not resolve canonical entry (unknown format)`);
          totalFailed++;
          continue;
        }

        data.networkAddresses[chainId] = entry;
        fs.writeFileSync(filePath, JSON.stringify(data));
        versionPatched++;
      } catch (e) {
        console.error(`  WARNING: Failed to patch ${file}: ${e.message}`);
        totalFailed++;
      }
    }

    if (versionPatched > 0) {
      console.log(`  [${version}] Patched ${versionPatched} contracts in ${assetsDir}`);
      totalPatched += versionPatched;
    }
  }
}

console.log(`\nTotal: ${totalPatched} patched, ${totalSkipped} already patched, ${totalFailed} failed`);
console.log(`Across ${assetsDirs.length} safe-deployments copies for chain ${chainId}\n`);

if (totalPatched === 0 && totalSkipped === 0) {
  console.error('ERROR: No contracts were patched or found!');
  process.exit(1);
}

if (totalFailed > 0) {
  console.error(`WARNING: ${totalFailed} files could not be patched`);
  // Don't exit 1 here — partial patching is better than no patching
}
