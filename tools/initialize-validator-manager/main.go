package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/api/info"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
)

var (
	rpcURL           string
	proxyAddress     string
	subnetID         string
	chainID          string
	conversionTxHash string
	privateKey       string
	privateKeyFile   string
	managerType      string
	icmContractsPath string
	glacierAPIKey    string
	useLocalSigAgg   bool
	sigAggURL        string
	networkName      string
	validatorIPs     string
	churnPeriod      uint64
	maxChurnPercent  uint
	outputFile       string
	jsonOutput       bool
	skipDeploy       bool
	skipUpgrade      bool
	skipInitSettings bool
	skipInitValSet   bool
)

// Output represents the JSON output structure
type Output struct {
	Implementation    string `json:"implementation"`
	Proxy             string `json:"proxy"`
	PoAManager        string `json:"poa_manager,omitempty"`
	InitSettingsTx    string `json:"init_settings_tx,omitempty"`
	InitValidatorsTx  string `json:"init_validators_tx,omitempty"`
	Success           bool   `json:"success"`
	Error             string `json:"error,omitempty"`
}

func main() {
	flag.StringVar(&rpcURL, "rpc-url", "", "L1 chain RPC URL (required)")
	flag.StringVar(&proxyAddress, "proxy-address", "", "Genesis proxy address to upgrade (required)")
	flag.StringVar(&subnetID, "subnet-id", "", "Subnet ID (required)")
	flag.StringVar(&chainID, "chain-id", "", "Chain ID / Blockchain ID (required)")
	flag.StringVar(&conversionTxHash, "conversion-tx", "", "ConvertSubnetToL1Tx hash for warp signature (required)")
	flag.StringVar(&privateKey, "private-key", "", "Private key (0x... format)")
	flag.StringVar(&privateKeyFile, "private-key-file", "", "File containing private key")
	flag.StringVar(&managerType, "manager-type", "poa", "Validator manager type: poa, native-staking, erc20-staking")
	flag.StringVar(&icmContractsPath, "contracts-path", "", "Path to icm-contracts repository (or set ICM_CONTRACTS_PATH)")
	flag.StringVar(&glacierAPIKey, "glacier-api-key", "", "Glacier API key (or set GLACIER_API_KEY)")
	flag.BoolVar(&useLocalSigAgg, "local-sig-agg", false, "Use local signature aggregator instead of Glacier")
	flag.StringVar(&sigAggURL, "sig-agg-url", "http://localhost:8080", "Local signature aggregator URL")
	flag.StringVar(&networkName, "network", "fuji", "Network: fuji or mainnet")
	flag.StringVar(&validatorIPs, "validator-ips", "", "Comma-separated validator IPs (for local sig-agg)")
	flag.Uint64Var(&churnPeriod, "churn-period", 0, "Churn period in seconds (default: 0)")
	flag.UintVar(&maxChurnPercent, "max-churn-percent", 20, "Maximum churn percentage (default: 20)")
	flag.StringVar(&outputFile, "output", "validator-manager.json", "Output file for deployment info")
	flag.BoolVar(&jsonOutput, "json", false, "Output results as JSON")
	flag.BoolVar(&skipDeploy, "skip-deploy", false, "Skip deploying implementation (use if already deployed)")
	flag.BoolVar(&skipUpgrade, "skip-upgrade", false, "Skip upgrading proxy (use if already upgraded)")
	flag.BoolVar(&skipInitSettings, "skip-init-settings", false, "Skip initializing settings (use if already initialized)")
	flag.BoolVar(&skipInitValSet, "skip-init-validator-set", false, "Skip initializing validator set")
	flag.Parse()

	if err := run(); err != nil {
		if jsonOutput {
			output := Output{Success: false, Error: err.Error()}
			jsonBytes, _ := json.MarshalIndent(output, "", "  ")
			fmt.Println(string(jsonBytes))
		} else {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		}
		os.Exit(1)
	}
}

func run() error {
	// Validate required parameters
	if rpcURL == "" {
		return fmt.Errorf("--rpc-url is required")
	}
	if proxyAddress == "" {
		return fmt.Errorf("--proxy-address is required")
	}
	if subnetID == "" {
		return fmt.Errorf("--subnet-id is required")
	}
	if chainID == "" {
		return fmt.Errorf("--chain-id is required")
	}
	if conversionTxHash == "" && !skipInitValSet {
		return fmt.Errorf("--conversion-tx is required (or use --skip-init-validator-set)")
	}

	// Load private key
	privKeyHex, err := loadPrivateKey()
	if err != nil {
		return fmt.Errorf("failed to load private key: %w", err)
	}

	// Get owner address from private key
	ownerAddress, err := getAddressFromPrivateKey(privKeyHex)
	if err != nil {
		return fmt.Errorf("failed to derive address: %w", err)
	}

	// Find contracts path
	contractsPath := icmContractsPath
	if contractsPath == "" {
		contractsPath = os.Getenv("ICM_CONTRACTS_PATH")
	}
	if contractsPath == "" {
		// Try common locations
		possiblePaths := []string{
			"../icm-contracts",
			"../../icm-contracts",
			"../../../icm-contracts",
			os.Getenv("HOME") + "/code/icm-contracts",
		}
		for _, p := range possiblePaths {
			if _, err := os.Stat(p + "/foundry.toml"); err == nil {
				contractsPath = p
				break
			}
		}
	}
	if contractsPath == "" {
		return fmt.Errorf("icm-contracts path not found. Set ICM_CONTRACTS_PATH or --contracts-path")
	}

	// Check forge is available
	if _, err := exec.LookPath("forge"); err != nil {
		return fmt.Errorf("forge not found. Install foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup")
	}

	ctx := context.Background()
	output := Output{Proxy: proxyAddress}

	if !jsonOutput {
		fmt.Println("=== Initialize Validator Manager ===")
		fmt.Printf("Network:      %s\n", networkName)
		fmt.Printf("RPC URL:      %s\n", rpcURL)
		fmt.Printf("Proxy:        %s\n", proxyAddress)
		fmt.Printf("Subnet ID:    %s\n", subnetID)
		fmt.Printf("Chain ID:     %s\n", chainID)
		fmt.Printf("Manager Type: %s\n", managerType)
		fmt.Println()
	}

	// Parse IDs
	parsedSubnetID, err := ids.FromString(subnetID)
	if err != nil {
		return fmt.Errorf("invalid subnet ID: %w", err)
	}
	parsedChainID, err := ids.FromString(chainID)
	if err != nil {
		return fmt.Errorf("invalid chain ID: %w", err)
	}

	var implAddress string

	// Step 1: Deploy ValidatorManager implementation
	if !skipDeploy {
		if !jsonOutput {
			fmt.Println("[1/4] Deploying ValidatorManager implementation...")
		}

		implAddress, err = deployImplementation(ctx, contractsPath, rpcURL, privKeyHex, managerType)
		if err != nil {
			return fmt.Errorf("failed to deploy implementation: %w", err)
		}
		output.Implementation = implAddress

		if !jsonOutput {
			fmt.Printf("  Implementation: %s\n", implAddress)
		}
	} else {
		if !jsonOutput {
			fmt.Println("[1/4] Skipping implementation deployment")
		}
	}

	// Step 2: Upgrade proxy to point to implementation
	if !skipUpgrade && implAddress != "" {
		if !jsonOutput {
			fmt.Println("[2/4] Upgrading proxy to implementation...")
		}

		err = upgradeProxy(ctx, contractsPath, rpcURL, privKeyHex, proxyAddress, implAddress)
		if err != nil {
			return fmt.Errorf("failed to upgrade proxy: %w", err)
		}

		if !jsonOutput {
			fmt.Println("  Proxy upgraded successfully")
		}
	} else {
		if !jsonOutput {
			fmt.Println("[2/4] Skipping proxy upgrade")
		}
	}

	// Step 3: Initialize ValidatorManager settings
	if !skipInitSettings {
		if !jsonOutput {
			fmt.Println("[3/4] Initializing ValidatorManager settings...")
		}

		subnetIDHex := "0x" + hex.EncodeToString(parsedSubnetID[:])
		txHash, err := initializeSettings(ctx, contractsPath, rpcURL, privKeyHex, proxyAddress, ownerAddress, subnetIDHex, churnPeriod, uint8(maxChurnPercent))
		if err != nil {
			return fmt.Errorf("failed to initialize settings: %w", err)
		}
		output.InitSettingsTx = txHash

		if !jsonOutput {
			fmt.Printf("  Settings initialized: %s\n", txHash)
		}
	} else {
		if !jsonOutput {
			fmt.Println("[3/4] Skipping settings initialization")
		}
	}

	// Step 3.5: Deploy PoAManager if needed
	if managerType == "poa" && !skipDeploy {
		if !jsonOutput {
			fmt.Println("  Deploying PoAManager...")
		}

		poaAddress, err := deployPoAManager(ctx, contractsPath, rpcURL, privKeyHex, ownerAddress, proxyAddress)
		if err != nil {
			return fmt.Errorf("failed to deploy PoAManager: %w", err)
		}
		output.PoAManager = poaAddress

		if !jsonOutput {
			fmt.Printf("  PoAManager: %s\n", poaAddress)
		}

		// Transfer ownership to PoAManager
		if !jsonOutput {
			fmt.Println("  Transferring ValidatorManager ownership to PoAManager...")
		}
		err = transferOwnership(ctx, contractsPath, rpcURL, privKeyHex, proxyAddress, poaAddress)
		if err != nil {
			return fmt.Errorf("failed to transfer ownership: %w", err)
		}
		if !jsonOutput {
			fmt.Println("  Ownership transferred")
		}
	}

	// Step 4: Initialize validator set with warp message
	if !skipInitValSet {
		if !jsonOutput {
			fmt.Println("[4/4] Initializing validator set...")
		}

		// Get validator info
		validatorInfo, err := gatherValidatorInfo(ctx, validatorIPs, rpcURL)
		if err != nil {
			return fmt.Errorf("failed to gather validator info: %w", err)
		}

		// Get aggregated signature
		var signedMessage []byte
		if useLocalSigAgg {
			if !jsonOutput {
				fmt.Println("  Using local signature aggregator...")
			}
			signedMessage, err = getLocalAggregatedSignature(ctx, sigAggURL, parsedSubnetID, parsedChainID, proxyAddress, validatorInfo)
		} else {
			if !jsonOutput {
				fmt.Println("  Fetching signature from Glacier API...")
			}
			apiKey := glacierAPIKey
			if apiKey == "" {
				apiKey = os.Getenv("GLACIER_API_KEY")
			}
			signedMessage, err = waitForGlacierSignature(ctx, networkName, conversionTxHash, apiKey)
		}
		if err != nil {
			return fmt.Errorf("failed to get aggregated signature: %w", err)
		}

		if !jsonOutput {
			fmt.Printf("  Signature received (%d bytes)\n", len(signedMessage))
		}

		// Call initializeValidatorSet
		if !jsonOutput {
			fmt.Println("  Calling initializeValidatorSet...")
		}
		txHash, err := initializeValidatorSet(ctx, contractsPath, rpcURL, privKeyHex, proxyAddress, parsedSubnetID, parsedChainID, validatorInfo, signedMessage)
		if err != nil {
			return fmt.Errorf("failed to initialize validator set: %w", err)
		}
		output.InitValidatorsTx = txHash

		if !jsonOutput {
			fmt.Printf("  Validator set initialized: %s\n", txHash)
		}
	} else {
		if !jsonOutput {
			fmt.Println("[4/4] Skipping validator set initialization")
		}
	}

	output.Success = true

	// Save output
	outputBytes, _ := json.MarshalIndent(output, "", "  ")
	if err := os.WriteFile(outputFile, outputBytes, 0644); err != nil {
		if !jsonOutput {
			fmt.Printf("Warning: failed to save output file: %v\n", err)
		}
	}

	if jsonOutput {
		fmt.Println(string(outputBytes))
	} else {
		fmt.Println()
		fmt.Println("=== Validator Manager Initialized Successfully ===")
		fmt.Printf("Implementation: %s\n", output.Implementation)
		fmt.Printf("Proxy:          %s\n", output.Proxy)
		if output.PoAManager != "" {
			fmt.Printf("PoAManager:     %s\n", output.PoAManager)
		}
		fmt.Printf("Output saved:   %s\n", outputFile)
	}

	return nil
}

func loadPrivateKey() (string, error) {
	var keyStr string

	if privateKey != "" {
		keyStr = privateKey
	} else if privateKeyFile != "" {
		data, err := os.ReadFile(privateKeyFile)
		if err != nil {
			return "", err
		}
		keyStr = strings.TrimSpace(string(data))
	} else if envKey := os.Getenv("AVALANCHE_PRIVATE_KEY"); envKey != "" {
		keyStr = envKey
	} else {
		return "", fmt.Errorf("no private key provided")
	}

	// Normalize to 0x format
	keyStr = strings.TrimPrefix(keyStr, "PrivateKey-")
	if !strings.HasPrefix(keyStr, "0x") {
		keyStr = "0x" + keyStr
	}

	return keyStr, nil
}

func getAddressFromPrivateKey(privKeyHex string) (string, error) {
	keyBytes, err := hex.DecodeString(strings.TrimPrefix(privKeyHex, "0x"))
	if err != nil {
		return "", err
	}

	privKey, err := secp256k1.ToPrivateKey(keyBytes)
	if err != nil {
		return "", err
	}

	return privKey.Address().String(), nil
}

func deployImplementation(ctx context.Context, contractsPath, rpcURL, privKey, managerType string) (string, error) {
	var contract string
	switch managerType {
	case "poa":
		contract = "src/validator-manager/ValidatorManager.sol:ValidatorManager"
	case "native-staking":
		contract = "src/validator-manager/NativeTokenStakingManager.sol:NativeTokenStakingManager"
	case "erc20-staking":
		contract = "src/validator-manager/ERC20TokenStakingManager.sol:ERC20TokenStakingManager"
	default:
		return "", fmt.Errorf("unknown manager type: %s", managerType)
	}

	// Deploy with ICMInitializable.Allowed = 0
	return forgeCreate(ctx, contractsPath, rpcURL, privKey, contract, "--constructor-args", "0")
}

func upgradeProxy(ctx context.Context, contractsPath, rpcURL, privKey, proxyAddress, implAddress string) error {
	// Call upgradeTo on the proxy
	// For TransparentUpgradeableProxy, we need to call through the admin
	// But if caller is admin, it will forward to upgradeTo
	_, err := castSend(ctx, rpcURL, privKey, proxyAddress, "upgradeTo(address)", implAddress)
	return err
}

func initializeSettings(ctx context.Context, contractsPath, rpcURL, privKey, proxyAddress, admin, subnetIDHex string, churnPeriod uint64, maxChurn uint8) (string, error) {
	// function initialize(ValidatorManagerSettings calldata settings)
	// struct ValidatorManagerSettings { address admin; bytes32 subnetID; uint64 churnPeriodSeconds; uint8 maximumChurnPercentage; }

	settingsTuple := fmt.Sprintf("(%s,%s,%d,%d)", admin, subnetIDHex, churnPeriod, maxChurn)
	return castSend(ctx, rpcURL, privKey, proxyAddress, "initialize((address,bytes32,uint64,uint8))", settingsTuple)
}

func deployPoAManager(ctx context.Context, contractsPath, rpcURL, privKey, owner, validatorManager string) (string, error) {
	return forgeCreate(ctx, contractsPath, rpcURL, privKey,
		"src/validator-manager/PoAValidatorManager.sol:PoAValidatorManager",
		"--constructor-args", owner, validatorManager)
}

func transferOwnership(ctx context.Context, contractsPath, rpcURL, privKey, proxyAddress, newOwner string) error {
	_, err := castSend(ctx, rpcURL, privKey, proxyAddress, "transferOwnership(address)", newOwner)
	return err
}

type ValidatorInfo struct {
	NodeID    ids.NodeID
	PublicKey []byte
	Weight    uint64
}

func gatherValidatorInfo(ctx context.Context, validatorIPsStr, rpcURL string) ([]ValidatorInfo, error) {
	var ips []string

	if validatorIPsStr != "" {
		ips = strings.Split(validatorIPsStr, ",")
	} else {
		// Extract IP from RPC URL
		parts := strings.Split(strings.TrimPrefix(rpcURL, "http://"), ":")
		if len(parts) > 0 {
			ips = []string{parts[0]}
		}
	}

	var validators []ValidatorInfo
	for _, ip := range ips {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}

		uri := fmt.Sprintf("http://%s:9650", ip)
		client := info.NewClient(uri)

		nodeID, pop, err := client.GetNodeID(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to get node info from %s: %w", ip, err)
		}

		validators = append(validators, ValidatorInfo{
			NodeID:    nodeID,
			PublicKey: pop.PublicKey[:],
			Weight:    1000, // Default weight
		})
	}

	if len(validators) == 0 {
		return nil, fmt.Errorf("no validators found")
	}

	return validators, nil
}

func getLocalAggregatedSignature(ctx context.Context, sigAggURL string, subnetID, chainID ids.ID, managerAddress string, validators []ValidatorInfo) ([]byte, error) {
	// TODO: Implement local signature aggregator call
	return nil, fmt.Errorf("local signature aggregator not yet implemented - use Glacier API")
}

func waitForGlacierSignature(ctx context.Context, network, txHash, apiKey string) ([]byte, error) {
	// Map network names
	glacierNetwork := network
	if network == "fuji" {
		glacierNetwork = "testnet"
	}

	url := fmt.Sprintf("https://glacier-api.avax.network/v1/networks/%s/signatureAggregator/aggregateSignatures?txHash=%s",
		glacierNetwork, txHash)

	for i := 0; i < 30; i++ {
		req, err := NewRequestWithContext(ctx, "GET", url)
		if err != nil {
			return nil, err
		}
		if apiKey != "" {
			req.Header.Set("x-glacier-api-key", apiKey)
		}

		resp, err := httpClient.Do(req)
		if err != nil {
			time.Sleep(10 * time.Second)
			continue
		}

		if resp.StatusCode == 200 {
			var result struct {
				SignedMessage string `json:"signedMessage"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
				resp.Body.Close()
				return nil, err
			}
			resp.Body.Close()

			return hex.DecodeString(strings.TrimPrefix(result.SignedMessage, "0x"))
		}
		resp.Body.Close()

		fmt.Printf("  Waiting for signature (attempt %d/30)...\n", i+1)
		time.Sleep(10 * time.Second)
	}

	return nil, fmt.Errorf("timeout waiting for signature")
}

func initializeValidatorSet(ctx context.Context, contractsPath, rpcURL, privKey, proxyAddress string, subnetID, chainID ids.ID, validators []ValidatorInfo, signedMessage []byte) (string, error) {
	// Build ConversionData
	// struct ConversionData { bytes32 subnetID; bytes32 validatorManagerBlockchainID; address validatorManagerAddress; InitialValidator[] initialValidators; }
	// struct InitialValidator { bytes nodeID; bytes blsPublicKey; uint64 weight; }

	validatorStrs := make([]string, len(validators))
	for i, v := range validators {
		validatorStrs[i] = fmt.Sprintf("(0x%s,0x%s,%d)",
			hex.EncodeToString(v.NodeID.Bytes()),
			hex.EncodeToString(v.PublicKey),
			v.Weight)
	}

	conversionData := fmt.Sprintf("(0x%s,0x%s,%s,[%s])",
		hex.EncodeToString(subnetID[:]),
		hex.EncodeToString(chainID[:]),
		proxyAddress,
		strings.Join(validatorStrs, ","))

	// The warp message needs to be sent via access list
	warpPrecompile := "0x0200000000000000000000000000000000000005"
	warpMessageHex := "0x" + hex.EncodeToString(signedMessage)

	cmd := exec.CommandContext(ctx, "cast", "send",
		"--rpc-url", rpcURL,
		"--private-key", privKey,
		"--json",
		"--access-list", fmt.Sprintf("%s:%s", warpPrecompile, warpMessageHex),
		proxyAddress,
		"initializeValidatorSet((bytes32,bytes32,address,(bytes,bytes,uint64)[]),uint32)",
		conversionData, "0")

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cast send failed: %w\nOutput: %s", err, string(output))
	}

	var result struct {
		TransactionHash string `json:"transactionHash"`
	}
	if err := json.Unmarshal(output, &result); err == nil && result.TransactionHash != "" {
		return result.TransactionHash, nil
	}

	return "", nil
}

func forgeCreate(ctx context.Context, workDir, rpcURL, privKey, contract string, args ...string) (string, error) {
	cmdArgs := []string{"create", "--rpc-url", rpcURL, "--private-key", privKey, "--json", contract}
	cmdArgs = append(cmdArgs, args...)

	cmd := exec.CommandContext(ctx, "forge", cmdArgs...)
	cmd.Dir = workDir

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("forge create failed: %w\nOutput: %s", err, string(output))
	}

	var result struct {
		DeployedTo string `json:"deployedTo"`
	}
	if err := json.Unmarshal(output, &result); err != nil {
		return "", fmt.Errorf("failed to parse output: %s", string(output))
	}

	return result.DeployedTo, nil
}

func castSend(ctx context.Context, rpcURL, privKey, to, sig string, args ...string) (string, error) {
	cmdArgs := []string{"send", "--rpc-url", rpcURL, "--private-key", privKey, "--json", to, sig}
	cmdArgs = append(cmdArgs, args...)

	cmd := exec.CommandContext(ctx, "cast", cmdArgs...)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cast send failed: %w\nOutput: %s", err, string(output))
	}

	var result struct {
		TransactionHash string `json:"transactionHash"`
	}
	json.Unmarshal(output, &result)

	return result.TransactionHash, nil
}

// HTTP client for Glacier API
var httpClient = &http.Client{Timeout: 60 * time.Second}

func NewRequestWithContext(ctx context.Context, method, url string) (*http.Request, error) {
	return http.NewRequestWithContext(ctx, method, url, nil)
}
