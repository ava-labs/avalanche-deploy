package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/api/info"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/cb58"
	"github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
	"github.com/ava-labs/avalanchego/utils/units"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanchego/vms/secp256k1fx"
	"github.com/ava-labs/avalanchego/wallet/subnet/primary"
)

// Config holds the deployment configuration
type Config struct {
	Network          string   `json:"network"`
	ValidatorIPs     []string `json:"validator_ips"`
	ChainName        string   `json:"chain_name"`
	GenesisFile      string   `json:"genesis_file"`
	ValidatorBalance uint64   `json:"validator_balance_avax"` // AVAX per validator
}

var (
	network        string
	privateKey     string
	privateKeyFile string
	configFile     string
	outputFile     string
	validatorIPs   string
	genesisFile    string
	chainName      string
	balanceAVAX    uint64
)

func main() {
	flag.StringVar(&network, "network", "fuji", "Network: fuji or mainnet")
	flag.StringVar(&privateKey, "private-key", "", "Private key (PrivateKey-... format)")
	flag.StringVar(&privateKeyFile, "private-key-file", "", "File containing private key")
	flag.StringVar(&configFile, "config", "", "Config file (YAML/JSON)")
	flag.StringVar(&outputFile, "output", "l1.env", "Output file for subnet/chain IDs")
	flag.StringVar(&validatorIPs, "validators", "", "Comma-separated validator IPs")
	flag.StringVar(&genesisFile, "genesis", "genesis.json", "Genesis file path")
	flag.StringVar(&chainName, "chain-name", "my-l1", "Name for the L1 chain")
	flag.Uint64Var(&balanceAVAX, "validator-balance", 1, "Initial balance per validator in AVAX")
	flag.Parse()

	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	// Load private key
	key, err := loadPrivateKey()
	if err != nil {
		return fmt.Errorf("failed to load private key: %w", err)
	}

	// Parse validator IPs
	ips, err := parseValidatorIPs()
	if err != nil {
		return fmt.Errorf("failed to parse validator IPs: %w", err)
	}

	if len(ips) == 0 {
		return fmt.Errorf("no validator IPs provided. Use --validators or set VALIDATOR_*_IP env vars")
	}

	// Load genesis
	genesisBytes, err := os.ReadFile(genesisFile)
	if err != nil {
		return fmt.Errorf("failed to read genesis file %s: %w", genesisFile, err)
	}

	// Get network configuration
	networkID, rpcEndpoint := getNetworkConfig(network)

	fmt.Println("=== Create Avalanche L1 ===")
	fmt.Printf("Network:    %s (ID: %d)\n", network, networkID)
	fmt.Printf("Chain Name: %s\n", chainName)
	fmt.Printf("Validators: %d\n", len(ips))
	for i, ip := range ips {
		fmt.Printf("  [%d] %s\n", i+1, ip)
	}
	fmt.Println()

	ctx := context.Background()

	// Build node URIs
	nodeURIs := make([]string, len(ips))
	for i, ip := range ips {
		nodeURIs[i] = fmt.Sprintf("http://%s:9650", ip)
	}

	// Create wallet
	fmt.Println("[1/4] Creating wallet...")
	kc := secp256k1fx.NewKeychain(key)
	wallet, err := primary.MakePWallet(ctx, nodeURIs[0], kc, primary.WalletConfig{})
	if err != nil {
		return fmt.Errorf("failed to create wallet: %w", err)
	}

	// Check balance
	pBuilder := wallet.P().Builder()
	balance, err := pBuilder.GetBalance()
	if err != nil {
		return fmt.Errorf("failed to get balance: %w", err)
	}
	fmt.Printf("  Wallet balance: %d nAVAX (%.2f AVAX)\n", balance, float64(balance)/float64(units.Avax))

	requiredBalance := uint64(len(ips)) * balanceAVAX * units.Avax
	if balance < requiredBalance {
		return fmt.Errorf("insufficient balance: have %d nAVAX, need %d nAVAX", balance, requiredBalance)
	}

	// Create subnet
	fmt.Println("[2/4] Creating subnet...")
	owner := &secp256k1fx.OutputOwners{
		Threshold: 1,
		Addrs:     []ids.ShortID{key.Address()},
	}
	subnetTx, err := wallet.IssueCreateSubnetTx(owner)
	if err != nil {
		return fmt.Errorf("failed to create subnet: %w", err)
	}
	subnetID := subnetTx.ID()
	fmt.Printf("  Subnet ID: %s\n", subnetID)

	// Re-sync wallet with subnet
	wallet, err = primary.MakePWallet(ctx, nodeURIs[0], kc, primary.WalletConfig{
		SubnetIDs: []ids.ID{subnetID},
	})
	if err != nil {
		return fmt.Errorf("failed to re-sync wallet: %w", err)
	}

	// Create chain
	fmt.Println("[3/4] Creating chain...")
	chainTx, err := wallet.IssueCreateChainTx(
		subnetID,
		genesisBytes,
		constants.SubnetEVMID,
		nil,
		chainName,
	)
	if err != nil {
		return fmt.Errorf("failed to create chain: %w", err)
	}
	chainID := chainTx.ID()
	fmt.Printf("  Chain ID: %s\n", chainID)

	// Gather validator info and convert to L1
	fmt.Println("[4/4] Converting subnet to L1...")
	fmt.Println("  Gathering validator info...")

	validators := make([]*txs.ConvertSubnetToL1Validator, 0, len(nodeURIs))
	for i, uri := range nodeURIs {
		infoClient := info.NewClient(uri)
		nodeID, nodePoP, err := infoClient.GetNodeID(ctx)
		if err != nil {
			return fmt.Errorf("failed to get node %d info from %s: %w", i+1, uri, err)
		}
		fmt.Printf("    Node %d: %s\n", i+1, nodeID)

		validators = append(validators, &txs.ConvertSubnetToL1Validator{
			NodeID:  nodeID.Bytes(),
			Weight:  units.Schmeckle, // Validator weight
			Balance: balanceAVAX * units.Avax,
			Signer:  *nodePoP,
		})
	}

	fmt.Println("  Issuing ConvertSubnetToL1Tx...")
	_, err = wallet.IssueConvertSubnetToL1Tx(
		subnetID,
		chainID,
		[]byte{}, // Empty manager address
		validators,
	)
	if err != nil {
		return fmt.Errorf("failed to convert subnet to L1: %w", err)
	}

	// Wait for chain
	fmt.Println("  Waiting for chain to be ready...")
	time.Sleep(10 * time.Second)

	// Verify chain is accessible
	for i, ip := range ips {
		rpcURL := fmt.Sprintf("http://%s:9650/ext/bc/%s/rpc", ip, chainID)
		fmt.Printf("  Checking RPC [%d]: %s\n", i+1, rpcURL)
	}

	// Write output
	content := fmt.Sprintf(`# Avalanche L1 Configuration
# Generated: %s
# Network: %s

SUBNET_ID=%s
CHAIN_ID=%s
NETWORK=%s

# RPC Endpoints
%s
`,
		time.Now().Format(time.RFC3339),
		network,
		subnetID,
		chainID,
		network,
		buildRPCEndpoints(ips, chainID),
	)

	if err := os.WriteFile(outputFile, []byte(content), 0644); err != nil {
		return fmt.Errorf("failed to write output file: %w", err)
	}
	fmt.Printf("\nConfiguration written to: %s\n", outputFile)

	// Print summary
	fmt.Println()
	fmt.Println("=== L1 Created Successfully ===")
	fmt.Println()
	fmt.Printf("Subnet ID: %s\n", subnetID)
	fmt.Printf("Chain ID:  %s\n", chainID)
	fmt.Printf("Network:   %s\n", network)
	fmt.Println()
	fmt.Println("RPC Endpoints:")
	for i, ip := range ips {
		fmt.Printf("  [%d] http://%s:9650/ext/bc/%s/rpc\n", i+1, ip, chainID)
	}

	// Print explorer link if applicable
	if network == "fuji" {
		fmt.Println()
		fmt.Printf("Explorer: https://subnets-test.avax.network/c-chain/%s\n", chainID)
	}

	_ = rpcEndpoint // Silence unused variable for now

	return nil
}

func loadPrivateKey() (*secp256k1.PrivateKey, error) {
	var keyStr string

	// Priority: flag > file > env
	if privateKey != "" {
		keyStr = privateKey
	} else if privateKeyFile != "" {
		data, err := os.ReadFile(privateKeyFile)
		if err != nil {
			return nil, fmt.Errorf("failed to read key file: %w", err)
		}
		keyStr = strings.TrimSpace(string(data))
	} else if envKey := os.Getenv("AVALANCHE_PRIVATE_KEY"); envKey != "" {
		keyStr = envKey
	} else {
		return nil, fmt.Errorf("no private key provided. Use --private-key, --private-key-file, or AVALANCHE_PRIVATE_KEY env var")
	}

	// Parse the key
	keyStr = strings.TrimPrefix(keyStr, "PrivateKey-")
	keyBytes, err := cb58.Decode(keyStr)
	if err != nil {
		return nil, fmt.Errorf("failed to decode private key: %w", err)
	}

	key, err := secp256k1.ToPrivateKey(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}

	return key, nil
}

func parseValidatorIPs() ([]string, error) {
	var ips []string

	// From flag
	if validatorIPs != "" {
		for _, ip := range strings.Split(validatorIPs, ",") {
			ip = strings.TrimSpace(ip)
			if ip != "" {
				ips = append(ips, ip)
			}
		}
		return ips, nil
	}

	// From environment variables (VALIDATOR_1_IP, VALIDATOR_2_IP, etc.)
	for i := 1; ; i++ {
		ip := os.Getenv(fmt.Sprintf("VALIDATOR_%d_IP", i))
		if ip == "" {
			break
		}
		ips = append(ips, ip)
	}

	return ips, nil
}

func getNetworkConfig(network string) (uint32, string) {
	switch network {
	case "mainnet":
		return 1, "https://api.avax.network"
	case "fuji":
		return 5, "https://api.avax-test.network"
	default:
		// Default to fuji
		return 5, "https://api.avax-test.network"
	}
}

func buildRPCEndpoints(ips []string, chainID ids.ID) string {
	var lines []string
	for i, ip := range ips {
		lines = append(lines, fmt.Sprintf("RPC_%d_URL=http://%s:9650/ext/bc/%s/rpc", i+1, ip, chainID))
	}
	return strings.Join(lines, "\n")
}
