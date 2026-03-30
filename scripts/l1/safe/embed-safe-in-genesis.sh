#!/usr/bin/env bash
# Embed Safe v1.4.1 contract runtime bytecodes into a genesis.json file.
# This eliminates the need for deploy-contracts.sh — contracts exist from block 0.
#
# Usage: ./embed-safe-in-genesis.sh <genesis.json>
#   Modifies the file in-place. Idempotent (skips already-embedded contracts).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/runtime-bytecodes"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <genesis.json>"
  exit 1
fi

GENESIS="$1"
if [[ ! -f "$GENESIS" ]]; then
  echo "Error: $GENESIS not found"
  exit 1
fi

if [[ ! -f "${RUNTIME_DIR}/genesis-alloc.json" ]]; then
  echo "Error: ${RUNTIME_DIR}/genesis-alloc.json not found"
  echo "Run the runtime bytecode extraction first."
  exit 1
fi

python3 -c "
import json, sys

genesis_path = '${GENESIS}'
alloc_path = '${RUNTIME_DIR}/genesis-alloc.json'

with open(genesis_path) as f:
    genesis = json.load(f)

with open(alloc_path) as f:
    safe_alloc = json.load(f)

added = 0
skipped = 0
for addr, entry in safe_alloc.items():
    # Check both cased and lowercased versions
    if addr in genesis['alloc'] or addr.lower() in genesis['alloc']:
        print(f'  SKIP: {addr} (already in genesis)')
        skipped += 1
    else:
        genesis['alloc'][addr] = entry
        print(f'  ADD:  {addr}')
        added += 1

with open(genesis_path, 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')

print(f'\nDone: {added} added, {skipped} already present')
"