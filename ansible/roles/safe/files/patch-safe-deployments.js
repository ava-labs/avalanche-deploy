#!/usr/bin/env node
/**
 * Patch @safe-global/safe-deployments to add a custom chain.
 * Run inside the safe-wallet-web container BEFORE 'yarn build'.
 *
 * This adds the chain ID to all v1.4.1 contract networkAddresses,
 * using the canonical CREATE2 address (defaultAddress) for each contract.
 * This is equivalent to what AshAvalanche does with their safe-deployments fork.
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

// Patch all contract versions (v1.3.0 and v1.4.1) in ALL copies
const versions = ['v1.3.0', 'v1.4.1'];
let totalPatched = 0;

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

        if (data.networkAddresses && data.defaultAddress) {
          if (data.networkAddresses[chainId]) continue; // already patched

          data.networkAddresses[chainId] = data.defaultAddress;
          fs.writeFileSync(filePath, JSON.stringify(data));
          versionPatched++;
        }
      } catch (e) {
        console.error(`  WARNING: Failed to patch ${file}: ${e.message}`);
      }
    }

    if (versionPatched > 0) {
      console.log(`  [${version}] Patched ${versionPatched} contracts in ${assetsDir}`);
      totalPatched += versionPatched;
    }
  }
}

console.log(`\nTotal: ${totalPatched} contracts patched across ${assetsDirs.length} copies for chain ${chainId}\n`);

if (totalPatched === 0) {
  console.error('ERROR: No contracts were patched!');
  process.exit(1);
}
