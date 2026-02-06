# create-l1

CLI tool to create an Avalanche L1 (formerly Subnet) on Fuji or Mainnet.

## Prerequisites

1. **Funded P-Chain Address**: You need a P-Chain address with AVAX
   - Fuji: Get test AVAX from [faucet.avax.network](https://faucet.avax.network/)
   - Mainnet: Real AVAX required

2. **Running Validator Nodes**: Your validators must be running and synced with the network

3. **Go 1.21+**: Required to build the tool

## Build

```bash
go build -o create-l1 .
```

## Usage

### Basic Usage

```bash
# Set your private key (P-Chain format)
export AVALANCHE_PRIVATE_KEY=PrivateKey-...

# Set validator IPs
export VALIDATOR_1_IP=1.2.3.4
export VALIDATOR_2_IP=1.2.3.5
export VALIDATOR_3_IP=1.2.3.6

# Create L1 on Fuji
./create-l1 --network=fuji --genesis=genesis.json --chain-name=my-l1
```

### All Options

```bash
./create-l1 \
  --network=fuji \                    # fuji or mainnet
  --private-key=PrivateKey-... \      # Or use --private-key-file or AVALANCHE_PRIVATE_KEY
  --validators=1.2.3.4,1.2.3.5 \      # Or use VALIDATOR_*_IP env vars
  --genesis=genesis.json \            # Genesis file for your L1
  --chain-name=my-l1 \                # Name for your L1
  --validator-balance=1 \             # AVAX per validator (default: 1)
  --output=l1.env \                   # Output file (default: l1.env)
  --json                              # Optional machine-readable output
```

### Private Key Options

1. **Environment variable** (recommended):
   ```bash
   export AVALANCHE_PRIVATE_KEY=PrivateKey-ewoqjP7PxY4yr3iLTpLisriqt94hdyDFNgchSxGGztUrTXtNN
   ```

2. **File**:
   ```bash
   ./create-l1 --private-key-file=~/.avalanche/key.txt
   ```

3. **Flag** (not recommended for production):
   ```bash
   ./create-l1 --private-key=PrivateKey-...
   ```

### Validator IPs Options

1. **Environment variables**:
   ```bash
   export VALIDATOR_1_IP=1.2.3.4
   export VALIDATOR_2_IP=1.2.3.5
   export VALIDATOR_3_IP=1.2.3.6
   ```

2. **Flag**:
   ```bash
   ./create-l1 --validators=1.2.3.4,1.2.3.5,1.2.3.6
   ```

## Output

The tool creates an output file (default: `l1.env`) with:

```bash
SUBNET_ID=...
CHAIN_ID=...
CONVERSION_TX=...
EVM_CHAIN_ID=99999
NETWORK=fuji
RPC_1_URL=http://1.2.3.4:9650/ext/bc/.../rpc
RPC_2_URL=http://1.2.3.5:9650/ext/bc/.../rpc
RPC_3_URL=http://1.2.3.6:9650/ext/bc/.../rpc
```

`EVM_CHAIN_ID` is populated when `config.chainId` exists in the provided genesis.

## What Happens

1. **Create Subnet**: Issues `CreateSubnetTx` on P-Chain
2. **Create Chain**: Issues `CreateChainTx` with your genesis and SubnetEVM
3. **Convert to L1**: Issues `ConvertSubnetToL1Tx` with your validators
4. **Verify**: Checks that RPC endpoints are accessible

## Genesis File

Edit `genesis.json` in the repo root, or create your own:

```json
{
    "config": {
        "chainId": 12345,
        "feeConfig": {
            "gasLimit": 15000000,
            "targetBlockRate": 2,
            "minBaseFee": 25000000000,
            "targetGas": 15000000,
            "baseFeeChangeDenominator": 36,
            "minBlockGasCost": 0,
            "maxBlockGasCost": 1000000,
            "blockGasCostStep": 200000
        }
    },
    "alloc": {
        "0xYourAddress": {
            "balance": "0x..."
        }
    },
    "nonce": "0x0",
    "timestamp": "0x0",
    "extraData": "0x00",
    "gasLimit": "0xe4e1c0",
    "difficulty": "0x0",
    "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "coinbase": "0x0000000000000000000000000000000000000000",
    "number": "0x0",
    "gasUsed": "0x0",
    "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000"
}
```

## Troubleshooting

### "insufficient balance"
Your P-Chain address doesn't have enough AVAX. For Fuji, use the faucet.

### "failed to get node info"
Your validator nodes aren't running or aren't accessible. Check:
- Nodes are running and healthy: `curl http://IP:9650/ext/health`
- Firewall allows port 9650

### "failed to create wallet"
Can't connect to the first validator. Verify network connectivity.
