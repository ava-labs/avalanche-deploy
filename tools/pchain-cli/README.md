# pchain-cli

Command-line utilities for Avalanche P-Chain operations.

## Overview

`pchain-cli` provides a set of commands for working with the Avalanche P-Chain:

- **wallet** - Wallet operations (balance, address)
- **subnet** - Subnet management (create, convert)
- **chain** - Chain management (create)
- **node** - Node information (info)

This tool can be used standalone or as a library by other tools like `create-l1`.

## Installation

```bash
cd tools/pchain-cli
go build -o pchain-cli .

# With Ledger support
go build -tags ledger -o pchain-cli .
```

## Usage

### Wallet Commands

```bash
# Show wallet addresses
pchain-cli wallet address --private-key "PrivateKey-..."

# Check P-Chain balance
pchain-cli wallet balance --private-key "PrivateKey-..." --network fuji
```

### Node Commands

```bash
# Get node ID and BLS key
pchain-cli node info --ip 127.0.0.1
```

### Subnet Commands

```bash
# Create a new subnet
pchain-cli subnet create --network fuji --private-key "PrivateKey-..."

# Convert subnet to L1
pchain-cli subnet convert \
  --network fuji \
  --private-key "PrivateKey-..." \
  --subnet-id "..." \
  --chain-id "..." \
  --validators "10.0.0.1,10.0.0.2"
```

### Chain Commands

```bash
# Create a new chain on a subnet
pchain-cli chain create \
  --network fuji \
  --private-key "PrivateKey-..." \
  --subnet-id "..." \
  --genesis genesis.json \
  --name "mychain"
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `AVALANCHE_PRIVATE_KEY` | P-Chain private key (alternative to --private-key flag) |

## Private Key Formats

The following private key formats are supported:

- `PrivateKey-ewoqjP7PxY4yr3iLTp...` (Avalanche CB58 format)
- `0x56289e99c94b6912bfc12adc...` (Ethereum hex format)
- Raw CB58 or hex strings

## Using as a Library

```go
import (
    "github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/wallet"
    "github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/pchain"
    "github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/network"
    "github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/node"
)

// Parse a private key
keyBytes, _ := wallet.ParsePrivateKey("PrivateKey-...")
key, _ := wallet.ToPrivateKey(keyBytes)

// Create a wallet
config := network.GetConfig("fuji")
w, _ := wallet.NewWallet(ctx, key, config)

// Create a subnet
subnetID, _ := pchain.CreateSubnet(ctx, w)

// Get node info
info, _ := node.GetNodeInfo(ctx, "10.0.0.1")
```
