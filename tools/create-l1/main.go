package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/api/info"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
	"github.com/ava-labs/avalanchego/utils/units"
	"github.com/ava-labs/avalanchego/vms/platformvm/signer"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanchego/vms/secp256k1fx"
	"github.com/ava-labs/avalanchego/wallet/subnet/primary"
	dcrsecp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	"golang.org/x/crypto/sha3"

	// Use platform-cli libraries for common functionality
	pkgkeystore "github.com/ava-labs/platform-cli/pkg/keystore"
	"github.com/ava-labs/platform-cli/pkg/network"
	pkgwallet "github.com/ava-labs/platform-cli/pkg/wallet"
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
	networkName            string
	keyName                string
	configFile             string
	outputFile             string
	validatorIPs           string
	genesisFile            string
	chainName              string
	balanceAVAX            float64
	deployValidatorManager bool
	managerType            string
	contractsPath          string
	glacierAPIKey          string
	useLocalSigAgg         bool
	sigAggURL              string
	sigAggPort             uint
	startSigAgg            bool
	genesisProxyAddress    string
	jsonOutput             bool
)

// L1Output represents the JSON output structure for scripting
type L1Output struct {
	SubnetID         string            `json:"subnet_id"`
	ChainID          string            `json:"chain_id"`
	EVMChainID       string            `json:"evm_chain_id,omitempty"`
	ChainName        string            `json:"chain_name"`
	Network          string            `json:"network"`
	Validators       []ValidatorOutput `json:"validators"`
	RPCEndpoints     []string          `json:"rpc_endpoints"`
	ValidatorManager *VMOutput         `json:"validator_manager,omitempty"`
	ConversionTxID   string            `json:"conversion_tx_id,omitempty"`
	OutputFile       string            `json:"output_file"`
	CreatedAt        string            `json:"created_at"`
}

// ValidatorOutput represents a validator in the JSON output
type ValidatorOutput struct {
	NodeID string `json:"node_id"`
	IP     string `json:"ip"`
	Weight uint64 `json:"weight"`
}

// VMOutput represents validator manager contract addresses
type VMOutput struct {
	Implementation string `json:"implementation,omitempty"`
	Proxy          string `json:"proxy,omitempty"`
	PoAManager     string `json:"poa_manager,omitempty"`
}

func main() {
	flag.StringVar(&networkName, "network", "fuji", "Network: fuji or mainnet")
	flag.StringVar(&keyName, "key-name", "", "Key name from platform-cli keystore (~/.platform/keys, preferred)")
	flag.StringVar(&configFile, "config", "", "Config file (YAML/JSON)")
	flag.StringVar(&outputFile, "output", "l1.env", "Output file for subnet/chain IDs")
	flag.StringVar(&validatorIPs, "validators", "", "Comma-separated validator IPs")
	flag.StringVar(&genesisFile, "genesis", "", "Genesis file path (default: configs/l1/genesis/genesis.json in current or parent dirs)")
	flag.StringVar(&chainName, "chain-name", "my-l1", "Name for the L1 chain")
	flag.Float64Var(&balanceAVAX, "validator-balance", 1.0, "Initial balance per validator in AVAX (supports decimals, e.g., 0.1)")
	flag.BoolVar(&deployValidatorManager, "deploy-validator-manager", false, "Deploy ValidatorManager contracts (requires forge)")
	flag.StringVar(&managerType, "manager-type", "poa", "Validator manager type: poa, native-staking, erc20-staking")
	flag.StringVar(&contractsPath, "contracts-path", "", "Path to icm-services repository (or set ICM_SERVICES_PATH env)")
	flag.StringVar(&glacierAPIKey, "glacier-api-key", "", "Glacier API key for signature aggregation (or set GLACIER_API_KEY env)")
	flag.BoolVar(&useLocalSigAgg, "local-sig-agg", false, "Use local signature-aggregator instead of Glacier API (for private L1s)")
	flag.StringVar(&sigAggURL, "sig-agg-url", "", "URL of running signature-aggregator (e.g., http://localhost:8080)")
	flag.UintVar(&sigAggPort, "sig-agg-port", 8080, "Port for signature-aggregator when starting it")
	flag.BoolVar(&startSigAgg, "start-sig-agg", false, "Start a local signature-aggregator process")
	flag.StringVar(&genesisProxyAddress, "genesis-proxy-address", "", "Use existing proxy address from genesis (e.g., 0xfacade0000000000000000000000000000000000)")
	flag.BoolVar(&jsonOutput, "json", false, "Output results as JSON (for scripting)")
	flag.Parse()

	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	// Validate chain name (must be alphanumeric only)
	if err := validateChainName(chainName); err != nil {
		return err
	}

	// Parse validator IPs
	ips, err := parseValidatorIPs()
	if err != nil {
		return fmt.Errorf("failed to parse validator IPs: %w", err)
	}

	if len(ips) == 0 {
		return fmt.Errorf("no validator IPs provided. Use --validators or set VALIDATOR_*_IP env vars")
	}

	// Resolve genesis file path
	if genesisFile == "" {
		genesisFile, err = findGenesisFile()
		if err != nil {
			return fmt.Errorf("failed to find genesis file: %w", err)
		}
	}

	// Load genesis
	genesisBytes, err := os.ReadFile(genesisFile)
	if err != nil {
		return fmt.Errorf("failed to read genesis file %s: %w", genesisFile, err)
	}
	evmChainID := extractEVMChainID(genesisBytes)

	// Get network configuration
	networkID, rpcEndpoint, err := getNetworkConfig(networkName)
	if err != nil {
		return fmt.Errorf("failed to get network config: %w", err)
	}

	fmt.Println("=== Create Avalanche L1 ===")
	fmt.Printf("Network:    %s (ID: %d)\n", networkName, networkID)
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

	// Initialize keychain and wallet
	var kc *secp256k1fx.Keychain
	var ownerAddress ids.ShortID

	fmt.Println("[1/4] Creating wallet...")
	key, err := loadPrivateKey()
	if err != nil {
		return fmt.Errorf("failed to load private key: %w", err)
	}
	ownerAddress = key.Address()

	// Derive Ethereum address and check genesis funding
	ethAddress := deriveEthAddress(key)
	funded, balance := checkGenesisFunding(genesisBytes, ethAddress)

	kc = secp256k1fx.NewKeychain(key)

	// Use public API for wallet/transactions since validator nodes may not be connected yet
	walletURI := rpcEndpoint
	if walletURI == "" {
		walletURI = nodeURIs[0]
	}
	fmt.Printf("  Using RPC endpoint: %s\n", walletURI)
	wallet, err := primary.MakePWallet(ctx, walletURI, kc, primary.WalletConfig{})
	if err != nil {
		return fmt.Errorf("failed to create wallet: %w", err)
	}

	fmt.Printf("  Wallet loaded successfully\n")
	fmt.Printf("  P-Chain Address: %s\n", ownerAddress)
	fmt.Printf("  EVM Address:     %s\n", ethAddress)
	fmt.Printf("  Required P-Chain balance: ~%.2f AVAX per validator\n", balanceAVAX)

	// Report genesis funding status
	if funded {
		fmt.Printf("  Genesis funding: ✓ (balance: %s)\n", balance)
	} else {
		fmt.Printf("  Genesis funding: ✗ (address not in genesis alloc)\n")
		fmt.Println("  WARNING: Your EVM address is not funded in the selected genesis file")
		fmt.Println("           You won't be able to deploy contracts or send transactions on the L1")
		fmt.Println("           Update the genesis alloc to include your address before proceeding")
	}

	// Create subnet
	fmt.Println("[2/4] Creating subnet...")
	owner := &secp256k1fx.OutputOwners{
		Threshold: 1,
		Addrs:     []ids.ShortID{ownerAddress},
	}
	fmt.Println("  Building and issuing CreateSubnetTx...")
	subnetTx, err := wallet.IssueCreateSubnetTx(owner)
	if err != nil {
		return fmt.Errorf("failed to create subnet: %w", err)
	}
	subnetID := subnetTx.ID()
	fmt.Printf("  Subnet ID: %s\n", subnetID)

	// Re-sync wallet with subnet (use public API)
	wallet, err = primary.MakePWallet(ctx, walletURI, kc, primary.WalletConfig{
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

	// Deploy validator manager contracts if requested
	var managerAddress []byte
	var vmDeployment *ValidatorManagerDeployment

	// If genesis proxy address is provided, use it as the manager address
	if genesisProxyAddress != "" {
		fmt.Println("[4/N] Using genesis proxy address as ValidatorManager...")
		// Parse the address
		addrStr := strings.TrimPrefix(genesisProxyAddress, "0x")
		if len(addrStr) != 40 {
			return fmt.Errorf("invalid genesis proxy address: %s (expected 40 hex chars)", genesisProxyAddress)
		}
		addrBytes, err := hex.DecodeString(addrStr)
		if err != nil {
			return fmt.Errorf("failed to decode genesis proxy address: %w", err)
		}
		managerAddress = addrBytes
		fmt.Printf("  Proxy Address: 0x%s\n", addrStr)
		fmt.Println("  NOTE: You must deploy the ValidatorManager implementation and upgrade the proxy AFTER L1 conversion")
	}

	if deployValidatorManager {
		fmt.Println("[4/6] Deploying ValidatorManager contracts...")

		// Wait for chain RPC to be ready
		fmt.Println("  Waiting for chain RPC to be ready...")
		time.Sleep(15 * time.Second)

		// Build the chain RPC URL
		chainRPCURL := fmt.Sprintf("http://%s:9650/ext/bc/%s/rpc", ips[0], chainID)
		fmt.Printf("  Chain RPC: %s\n", chainRPCURL)

		// Parse manager type
		var vmType ValidatorManagerType
		switch strings.ToLower(managerType) {
		case "poa":
			vmType = PoAValidatorManagerType
		case "native-staking", "native":
			vmType = NativeTokenStakingManagerType
		case "erc20-staking", "erc20":
			vmType = ERC20TokenStakingManagerType
		default:
			return fmt.Errorf("unknown manager type: %s (use: poa, native-staking, erc20-staking)", managerType)
		}

		// Get the private key hex for forge
		keyBytes := key.Bytes()
		privateKeyHex := "0x" + fmt.Sprintf("%x", keyBytes)

		vmDeployment, err = DeployValidatorManagerWithForge(
			ctx,
			chainRPCURL,
			privateKeyHex,
			subnetID,
			ownerAddress.String(),
			vmType,
			contractsPath,
		)
		if err != nil {
			return fmt.Errorf("failed to deploy validator manager: %w", err)
		}

		managerAddress, err = vmDeployment.GetManagerAddressForConversion()
		if err != nil {
			return fmt.Errorf("failed to get manager address: %w", err)
		}

		// Save deployment info
		deploymentFile := strings.TrimSuffix(outputFile, filepath.Ext(outputFile)) + "-contracts.json"
		if err := vmDeployment.SaveDeployment(deploymentFile); err != nil {
			fmt.Printf("  Warning: failed to save deployment info: %v\n", err)
		} else {
			fmt.Printf("  Contract addresses saved to: %s\n", deploymentFile)
		}

		fmt.Println("[5/6] Gathering validator info...")
	} else {
		fmt.Println("[4/5] Gathering validator info...")
	}

	// Gather validator info and convert to L1
	fmt.Println("  Gathering validator info...")

	validators := make([]*txs.ConvertSubnetToL1Validator, 0, len(nodeURIs))
	nodeIDs := make([]ids.NodeID, 0, len(nodeURIs))
	nodePoPs := make([]*signer.ProofOfPossession, 0, len(nodeURIs))
	weights := make([]uint64, 0, len(nodeURIs))

	for i, uri := range nodeURIs {
		infoClient := info.NewClient(uri)
		nodeID, nodePoP, err := infoClient.GetNodeID(ctx)
		if err != nil {
			return fmt.Errorf("failed to get node %d info from %s: %w", i+1, uri, err)
		}
		fmt.Printf("    Node %d: %s\n", i+1, nodeID)

		weight := units.Schmeckle
		validators = append(validators, &txs.ConvertSubnetToL1Validator{
			NodeID:  nodeID.Bytes(),
			Weight:  weight,
			Balance: uint64(balanceAVAX * float64(units.Avax)),
			Signer:  *nodePoP,
		})
		nodeIDs = append(nodeIDs, nodeID)
		nodePoPs = append(nodePoPs, nodePoP)
		weights = append(weights, weight)
	}

	if deployValidatorManager {
		fmt.Println("[6/7] Converting subnet to L1...")
	} else {
		fmt.Println("[5/5] Converting subnet to L1...")
	}
	fmt.Println("  Issuing ConvertSubnetToL1Tx...")
	conversionTx, err := wallet.IssueConvertSubnetToL1Tx(
		subnetID,
		chainID,
		managerAddress, // Use deployed validator manager address or empty
		validators,
	)
	if err != nil {
		return fmt.Errorf("failed to convert subnet to L1: %w", err)
	}
	conversionTxID := conversionTx.ID()
	fmt.Printf("  Conversion Tx: %s\n", conversionTxID)

	// Wait for chain
	fmt.Println("  Waiting for chain to be ready...")
	time.Sleep(10 * time.Second)

	// Initialize validator set if validator manager was deployed
	if deployValidatorManager && vmDeployment != nil {
		fmt.Println("[7/7] Initializing validator set...")

		// Build the chain RPC URL
		chainRPCURL := fmt.Sprintf("http://%s:9650/ext/bc/%s/rpc", ips[0], chainID)

		// Get the private key hex for cast
		keyBytes := key.Bytes()
		privateKeyHex := "0x" + fmt.Sprintf("%x", keyBytes)

		// Build ConversionData
		conversionData := BuildConversionData(
			subnetID,
			chainID,
			vmDeployment.ValidatorManagerProxy,
			nodeIDs,
			nodePoPs,
			weights,
		)

		var signedMessage []byte
		var useGlacierAPI = !useLocalSigAgg && !startSigAgg
		var sigAgg *SignatureAggregator

		if !useGlacierAPI && startSigAgg {
			// Start a local signature-aggregator
			fmt.Println("  Using local signature-aggregator for private L1...")
			fmt.Println("  Starting local signature-aggregator...")

			// Get the P-Chain API URL
			pChainAPI := fmt.Sprintf("http://%s:9650", ips[0])

			sigAgg = NewSignatureAggregator(
				nodeURIs,
				nodeIDs,
				subnetID,
				pChainAPI,
				uint16(sigAggPort),
			)

			// Generate config
			configDir := filepath.Dir(outputFile)
			configPath, err := sigAgg.GenerateConfig(configDir)
			if err != nil {
				return fmt.Errorf("failed to generate sig-agg config: %w", err)
			}
			fmt.Printf("    Config: %s\n", configPath)

			// Find binary
			icmPath := contractsPath
			if icmPath == "" {
				icmPath = os.Getenv("ICM_SERVICES_PATH")
			}
			if icmPath == "" {
				// Try common locations
				possiblePaths := []string{
					"../../../icm-services",
					"../../icm-services",
					filepath.Join(os.Getenv("HOME"), "code/icm-services"),
				}
				for _, p := range possiblePaths {
					if _, err := os.Stat(filepath.Join(p, "signature-aggregator")); err == nil {
						icmPath = p
						break
					}
				}
			}

			binaryPath, err := sigAgg.FindBinary(icmPath)
			if err != nil {
				fmt.Printf("  Warning: %v\n", err)
				fmt.Println("  Falling back to Glacier API...")
				useGlacierAPI = true
				sigAgg = nil
			} else {
				fmt.Printf("    Binary: %s\n", binaryPath)

				// Start the process
				if err := sigAgg.Start(ctx); err != nil {
					fmt.Printf("  Warning: failed to start sig-agg: %v\n", err)
					fmt.Println("  Falling back to Glacier API...")
					useGlacierAPI = true
					sigAgg = nil
				} else {
					defer sigAgg.Stop()
					sigAggURL = sigAgg.GetURL()
				}
			}
		} else if !useGlacierAPI && useLocalSigAgg {
			// Using existing local signature-aggregator URL
			fmt.Println("  Using local signature-aggregator for private L1...")
		}

		if !useGlacierAPI {
			// Build the unsigned warp message for the conversion
			fmt.Println("  Building SubnetToL1ConversionMessage...")
			unsignedMsg, justification, err := BuildSubnetToL1ConversionMessage(
				networkID,
				subnetID,
				chainID,
				vmDeployment.ValidatorManagerProxy,
				nodeIDs,
				nodePoPs,
				weights,
			)
			if err != nil {
				return fmt.Errorf("failed to build conversion message: %w", err)
			}

			// Call signature aggregator
			fmt.Println("  Requesting signatures from validators...")
			if sigAgg != nil {
				signedMessage, err = sigAgg.AggregateSignaturesWithRetry(
					ctx,
					unsignedMsg,
					justification,
					subnetID,
					67,
					30,
				)
			} else {
				signedMessage, err = CallLocalSignatureAggregatorWithRetry(
					ctx,
					sigAggURL,
					unsignedMsg,
					justification,
					subnetID,
					67,
					30,
				)
			}
			if err != nil {
				return fmt.Errorf("failed to aggregate signatures: %w", err)
			}
			fmt.Printf("    Signature received (%d bytes)\n", len(signedMessage))
		}

		if useGlacierAPI {
			// Use Glacier API
			apiKey := glacierAPIKey
			if apiKey == "" {
				apiKey = os.Getenv("GLACIER_API_KEY")
			}

			fmt.Println("  Fetching aggregated signature from Glacier API...")
			var err error
			signedMessage, err = WaitForAggregatedSignature(ctx, networkName, conversionTxID.String(), apiKey, 30)
			if err != nil {
				fmt.Printf("  Warning: failed to get signature from Glacier: %v\n", err)
				fmt.Println("  You can manually initialize later using the conversion tx hash")
				goto skipInit
			}
			fmt.Printf("    Signature received (%d bytes)\n", len(signedMessage))
		}

		// Call initializeValidatorSet on the contract
		fmt.Println("  Calling initializeValidatorSet...")
		err = InitializeValidatorSet(
			ctx,
			chainRPCURL,
			privateKeyHex,
			vmDeployment.ValidatorManagerProxy,
			conversionData,
			signedMessage,
			contractsPath,
		)
		if err != nil {
			fmt.Printf("  Warning: failed to initialize validator set: %v\n", err)
			fmt.Println("  You can manually initialize later")
		} else {
			fmt.Println("  Validator set initialized successfully!")
		}

	skipInit:
	}

	// Verify chain is accessible
	if !jsonOutput {
		for i, ip := range ips {
			rpcURL := fmt.Sprintf("http://%s:9650/ext/bc/%s/rpc", ip, chainID)
			fmt.Printf("  Checking RPC [%d]: %s\n", i+1, rpcURL)
		}
	}

	// Build RPC endpoints list
	rpcEndpoints := make([]string, len(ips))
	for i, ip := range ips {
		rpcEndpoints[i] = fmt.Sprintf("http://%s:9650/ext/bc/%s/rpc", ip, chainID)
	}

	// Build validators output
	validatorOutputs := make([]ValidatorOutput, len(nodeIDs))
	for i, nodeID := range nodeIDs {
		validatorOutputs[i] = ValidatorOutput{
			NodeID: nodeID.String(),
			IP:     ips[i],
			Weight: weights[i],
		}
	}

	// Build JSON output structure
	output := L1Output{
		SubnetID:       subnetID.String(),
		ChainID:        chainID.String(),
		EVMChainID:     evmChainID,
		ChainName:      chainName,
		Network:        networkName,
		Validators:     validatorOutputs,
		RPCEndpoints:   rpcEndpoints,
		ConversionTxID: conversionTxID.String(),
		OutputFile:     outputFile,
		CreatedAt:      time.Now().Format(time.RFC3339),
	}

	// Add validator manager info if deployed
	if vmDeployment != nil {
		output.ValidatorManager = &VMOutput{
			Implementation: vmDeployment.ValidatorManagerImpl,
			Proxy:          vmDeployment.ValidatorManagerProxy,
			PoAManager:     vmDeployment.PoAManager,
		}
	}

	// Write output file (always write the .env file)
	var vmSection string
	if vmDeployment != nil {
		vmSection = fmt.Sprintf(`
# Validator Manager Contracts
VALIDATOR_MANAGER_IMPL=%s
VALIDATOR_MANAGER_PROXY=%s
POA_MANAGER=%s
`,
			vmDeployment.ValidatorManagerImpl,
			vmDeployment.ValidatorManagerProxy,
			vmDeployment.PoAManager,
		)
	}
	evmChainSection := ""
	if evmChainID != "" {
		evmChainSection = fmt.Sprintf("EVM_CHAIN_ID=%s\n", evmChainID)
	}

	content := fmt.Sprintf(`# Avalanche L1 Configuration
# Generated: %s
# Network: %s

SUBNET_ID=%s
CHAIN_ID=%s
CONVERSION_TX=%s
CHAIN_NAME=%s
NETWORK=%s
%s%s
# RPC Endpoints
%s
`,
		time.Now().Format(time.RFC3339),
		networkName,
		subnetID,
		chainID,
		conversionTxID,
		chainName,
		networkName,
		evmChainSection,
		vmSection,
		buildRPCEndpoints(ips, chainID),
	)

	if err := os.WriteFile(outputFile, []byte(content), 0644); err != nil {
		return fmt.Errorf("failed to write output file: %w", err)
	}

	// Output JSON if requested
	if jsonOutput {
		jsonBytes, err := json.MarshalIndent(output, "", "  ")
		if err != nil {
			return fmt.Errorf("failed to marshal JSON output: %w", err)
		}
		fmt.Println(string(jsonBytes))
		return nil
	}

	// Print human-readable summary
	fmt.Printf("\nConfiguration written to: %s\n", outputFile)
	fmt.Println()
	fmt.Println("=== L1 Created Successfully ===")
	fmt.Println()
	fmt.Printf("Subnet ID: %s\n", subnetID)
	fmt.Printf("Chain ID:  %s\n", chainID)
	if evmChainID != "" {
		fmt.Printf("EVM ID:    %s\n", evmChainID)
	}
	fmt.Printf("Conversion Tx: %s\n", conversionTxID)
	fmt.Printf("Network:   %s\n", networkName)
	if vmDeployment != nil {
		fmt.Println()
		fmt.Println("Validator Manager:")
		fmt.Printf("  Implementation:  %s\n", vmDeployment.ValidatorManagerImpl)
		fmt.Printf("  Proxy:           %s\n", vmDeployment.ValidatorManagerProxy)
		if vmDeployment.PoAManager != "" {
			fmt.Printf("  PoAManager:      %s\n", vmDeployment.PoAManager)
		}
	}
	fmt.Println()
	fmt.Println("RPC Endpoints:")
	for i, ip := range ips {
		fmt.Printf("  [%d] http://%s:9650/ext/bc/%s/rpc\n", i+1, ip, chainID)
	}

	// Print explorer link if applicable
	if networkName == "fuji" {
		fmt.Println()
		fmt.Printf("Explorer: https://subnets-test.avax.network/c-chain/%s\n", chainID)
	}

	return nil
}

func loadPrivateKey() (*secp256k1.PrivateKey, error) {
	// Priority: key manager (--key-name) > default key > env fallback.
	if keyName != "" {
		return loadPrivateKeyFromKeystore(keyName)
	}
	if ks, err := pkgkeystore.Load(); err == nil {
		if defaultKey := ks.GetDefault(); defaultKey != "" {
			return loadPrivateKeyFromKeystore(defaultKey)
		}
	}
	// Check for balance override from env.
	if envBalance := os.Getenv("L1_VALIDATOR_BALANCE_AVAX"); envBalance != "" && balanceAVAX == 1.0 {
		if val, err := parseFloat64(envBalance); err == nil {
			balanceAVAX = val
		}
	}

	envKey := os.Getenv("AVALANCHE_PRIVATE_KEY")
	if envKey == "" {
		return nil, fmt.Errorf("no key provided. Use --key-name (preferred), set a platform-cli default key, or AVALANCHE_PRIVATE_KEY env var")
	}

	// Use platform-cli wallet package for env-key parsing.
	keyBytes, err := pkgwallet.ParsePrivateKey(envKey)
	if err != nil {
		return nil, err
	}

	return pkgwallet.ToPrivateKey(keyBytes)
}

func loadPrivateKeyFromKeystore(name string) (*secp256k1.PrivateKey, error) {
	if err := pkgkeystore.ValidateKeyName(name); err != nil {
		return nil, err
	}

	ks, err := pkgkeystore.Load()
	if err != nil {
		return nil, fmt.Errorf("failed to load keystore: %w", err)
	}
	if !ks.HasKey(name) {
		return nil, fmt.Errorf("key %q not found in keystore", name)
	}

	var password []byte
	if ks.IsEncrypted(name) {
		envPwd := os.Getenv("PLATFORM_CLI_KEY_PASSWORD")
		if envPwd == "" {
			return nil, fmt.Errorf("key %q is encrypted; set PLATFORM_CLI_KEY_PASSWORD", name)
		}
		password = []byte(envPwd)
		defer clearBytes(password)
	}

	keyBytes, err := ks.LoadKey(name, password)
	if err != nil {
		return nil, fmt.Errorf("failed to load key %q from keystore: %w", name, err)
	}
	defer clearBytes(keyBytes)

	return pkgwallet.ToPrivateKey(keyBytes)
}

func clearBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

func hexToBytes(hexStr string) ([]byte, error) {
	if len(hexStr)%2 != 0 {
		hexStr = "0" + hexStr
	}
	bytes := make([]byte, len(hexStr)/2)
	for i := 0; i < len(bytes); i++ {
		var b byte
		_, err := fmt.Sscanf(hexStr[i*2:i*2+2], "%02x", &b)
		if err != nil {
			return nil, err
		}
		bytes[i] = b
	}
	return bytes, nil
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

func getNetworkConfig(networkName string) (uint32, string, error) {
	// Use platform-cli network package for configuration
	return network.GetNetworkIDAndRPC(networkName)
}

func buildRPCEndpoints(ips []string, chainID ids.ID) string {
	var lines []string
	for i, ip := range ips {
		lines = append(lines, fmt.Sprintf("RPC_%d_URL=http://%s:9650/ext/bc/%s/rpc", i+1, ip, chainID))
	}
	return strings.Join(lines, "\n")
}

func parseUint64(s string) (uint64, error) {
	var val uint64
	_, err := fmt.Sscanf(s, "%d", &val)
	return val, err
}

func parseFloat64(s string) (float64, error) {
	var val float64
	_, err := fmt.Sscanf(s, "%f", &val)
	return val, err
}

// validateChainName checks that the chain name contains only alphanumeric characters
// Avalanche P-Chain rejects chain names with hyphens, spaces, or special characters
func validateChainName(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("chain name cannot be empty")
	}

	for _, ch := range name {
		isLower := ch >= 'a' && ch <= 'z'
		isUpper := ch >= 'A' && ch <= 'Z'
		isDigit := ch >= '0' && ch <= '9'
		if !isLower && !isUpper && !isDigit {
			return fmt.Errorf("invalid chain name %q: use only letters and numbers", name)
		}
	}

	return nil
}

func findGenesisFile() (string, error) {
	candidates := []string{
		filepath.Join("configs", "l1", "genesis", "genesis.json"),
		"genesis.json", // Backward-compatibility fallback
	}

	// Check current directory first
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			abs, _ := filepath.Abs(candidate)
			return abs, nil
		}
	}

	// Walk up parent directories (up to 7 levels)
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}

	dir := cwd
	for i := 0; i < 7; i++ {
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent

		for _, candidate := range candidates {
			genesisPath := filepath.Join(dir, candidate)
			if _, err := os.Stat(genesisPath); err == nil {
				return genesisPath, nil
			}
		}
	}

	return "", fmt.Errorf("genesis file not found in current or parent directories (looked for configs/l1/genesis/genesis.json and genesis.json). Use --genesis flag to specify path")
}

// deriveEthAddress derives an Ethereum address from a secp256k1 private key
// Ethereum address = last 20 bytes of keccak256(uncompressed public key without prefix)
func deriveEthAddress(key *secp256k1.PrivateKey) string {
	pubKey, err := dcrsecp.ParsePubKey(key.PublicKey().Bytes())
	if err != nil {
		return "0x0000000000000000000000000000000000000000"
	}

	uncompressed := pubKey.SerializeUncompressed()
	if len(uncompressed) != 65 {
		return "0x0000000000000000000000000000000000000000"
	}

	// Ethereum address is last 20 bytes of keccak256(uncompressed pubkey without 0x04 prefix).
	hash := sha3.NewLegacyKeccak256()
	_, _ = hash.Write(uncompressed[1:])
	sum := hash.Sum(nil)
	return "0x" + hex.EncodeToString(sum[12:])
}

// GenesisAlloc represents the alloc section of a genesis file
type GenesisAlloc struct {
	Balance string `json:"balance"`
}

// GenesisConfig represents a simplified genesis file structure
type GenesisConfig struct {
	Config     json.RawMessage         `json:"config"`
	Alloc      map[string]GenesisAlloc `json:"alloc"`
	Nonce      string                  `json:"nonce"`
	Timestamp  string                  `json:"timestamp"`
	ExtraData  string                  `json:"extraData"`
	GasLimit   string                  `json:"gasLimit"`
	Difficulty string                  `json:"difficulty"`
	MixHash    string                  `json:"mixHash"`
	Coinbase   string                  `json:"coinbase"`
	Number     string                  `json:"number"`
	GasUsed    string                  `json:"gasUsed"`
	ParentHash string                  `json:"parentHash"`
}

// checkGenesisFunding verifies if the given address is funded in the genesis
func checkGenesisFunding(genesisBytes []byte, address string) (bool, string) {
	var genesis GenesisConfig
	if err := json.Unmarshal(genesisBytes, &genesis); err != nil {
		return false, ""
	}

	// Normalize address (remove 0x prefix, lowercase)
	normalizedAddr := strings.ToLower(strings.TrimPrefix(address, "0x"))

	for addr, alloc := range genesis.Alloc {
		normalizedAlloc := strings.ToLower(strings.TrimPrefix(addr, "0x"))
		if normalizedAlloc == normalizedAddr {
			return true, alloc.Balance
		}
	}

	return false, ""
}

// extractEVMChainID returns the EVM chain ID from genesis config as a string.
func extractEVMChainID(genesisBytes []byte) string {
	var parsed struct {
		Config map[string]json.RawMessage `json:"config"`
	}
	if err := json.Unmarshal(genesisBytes, &parsed); err != nil || parsed.Config == nil {
		return ""
	}

	rawChainID, ok := parsed.Config["chainId"]
	if !ok || len(rawChainID) == 0 {
		return ""
	}

	// Try integer first (common case), then string fallback.
	var numeric json.Number
	if err := json.Unmarshal(rawChainID, &numeric); err == nil {
		return numeric.String()
	}

	var str string
	if err := json.Unmarshal(rawChainID, &str); err == nil {
		return strings.TrimSpace(str)
	}

	return ""
}
