package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
)

var (
	rpcURL                         string
	proxyAddress                   string
	subnetID                       string
	chainID                        string
	conversionTxHash               string
	conversionID                   string
	pChainURL                      string
	privateKey                     string
	privateKeyFile                 string
	managerType                    string
	icmContractsPath               string
	validatorMessagesLibrary       string
	validatorManagerImplementation string
	glacierAPIKey                  string
	useLocalSigAgg                 bool
	sigAggURL                      string
	networkName                    string
	validatorIPs                   string
	churnPeriod                    uint64
	maxChurnPercent                uint
	outputFile                     string
	jsonOutput                     bool
	preflightOnly                  bool
	skipDeploy                     bool
	skipUpgrade                    bool
	skipInitSettings               bool
	skipInitValSet                 bool
)

// Output represents the JSON output structure
type Output struct {
	Implementation   string `json:"implementation"`
	Library          string `json:"library,omitempty"`
	Proxy            string `json:"proxy"`
	PoAManager       string `json:"poa_manager,omitempty"`
	InitSettingsTx   string `json:"init_settings_tx,omitempty"`
	InitValidatorsTx string `json:"init_validators_tx,omitempty"`
	Success          bool   `json:"success"`
	Error            string `json:"error,omitempty"`
}

func main() {
	flag.StringVar(&rpcURL, "rpc-url", "", "L1 chain RPC URL (required)")
	flag.StringVar(&proxyAddress, "proxy-address", "", "Genesis proxy address to upgrade (required)")
	flag.StringVar(&subnetID, "subnet-id", "", "Subnet ID (required)")
	flag.StringVar(&chainID, "chain-id", "", "Chain ID / Blockchain ID (required)")
	flag.StringVar(&conversionTxHash, "conversion-tx", "", "Accepted ConvertSubnetToL1Tx hash (required unless validator-set initialization is skipped)")
	flag.StringVar(&conversionID, "conversion-id", "", "Optional expected SubnetToL1Conversion ID; when set it must match the ID derived from the accepted conversion transaction")
	flag.StringVar(&pChainURL, "p-chain-url", "", "Avalanche node base URL serving the P-Chain API (default: derived from --rpc-url)")
	flag.StringVar(&privateKey, "private-key", "", "Private key (0x... format)")
	flag.StringVar(&privateKeyFile, "private-key-file", "", "File containing private key")
	flag.StringVar(&managerType, "manager-type", "poa", "Validator manager type: poa, native-staking, erc20-staking")
	flag.StringVar(&icmContractsPath, "contracts-path", "", "Path to icm-contracts repository (or set ICM_CONTRACTS_PATH)")
	flag.StringVar(&validatorMessagesLibrary, "validator-messages-library", "", "Reuse an existing ValidatorMessages library deployment after an interrupted run")
	flag.StringVar(&validatorManagerImplementation, "validator-manager-implementation", "", "Reuse an existing ValidatorManager implementation deployment after an interrupted run")
	flag.StringVar(&glacierAPIKey, "glacier-api-key", "", "Glacier API key (or set GLACIER_API_KEY)")
	flag.BoolVar(&useLocalSigAgg, "local-sig-agg", false, "Use local signature aggregator instead of Glacier")
	flag.StringVar(&sigAggURL, "sig-agg-url", "http://localhost:8080", "Local signature aggregator URL")
	flag.StringVar(&networkName, "network", "fuji", "Network: fuji or mainnet")
	flag.StringVar(&validatorIPs, "validator-ips", "", "Deprecated; inventory validators are not used as conversion authority")
	flag.Uint64Var(&churnPeriod, "churn-period", 0, "Churn period in seconds (default: 0)")
	flag.UintVar(&maxChurnPercent, "max-churn-percent", 20, "Maximum churn percentage (default: 20)")
	flag.StringVar(&outputFile, "output", "validator-manager.json", "Output file for deployment info")
	flag.BoolVar(&jsonOutput, "json", false, "Output results as JSON")
	flag.BoolVar(&preflightOnly, "preflight-only", false, "Validate the conversion and signature without changing contracts or writing output")
	flag.BoolVar(&skipDeploy, "skip-deploy", false, "Skip deploying implementation (use if already deployed)")
	flag.BoolVar(&skipUpgrade, "skip-upgrade", false, "Skip upgrading proxy (use if already upgraded)")
	flag.BoolVar(&skipInitSettings, "skip-init-settings", false, "Skip initializing settings (use if already initialized)")
	flag.BoolVar(&skipInitValSet, "skip-init-validator-set", false, "Skip initializing validator set")
	flag.Parse()

	// run() populates output as each address is obtained so a failed run still
	// reports what was deployed; those addresses are the input to
	// --validator-messages-library / --validator-manager-implementation.
	var output Output
	if err := run(&output); err != nil {
		output.Success = false
		output.Error = err.Error()
		if jsonOutput {
			jsonBytes, _ := json.MarshalIndent(output, "", "  ")
			fmt.Println(string(jsonBytes))
		} else {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		}
		os.Exit(1)
	}
}

func run(output *Output) error {
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
	if !skipInitValSet && conversionTxHash == "" {
		return fmt.Errorf("--conversion-tx is required unless --skip-init-validator-set is used")
	}
	if preflightOnly && skipInitValSet {
		return fmt.Errorf("--preflight-only cannot be combined with --skip-init-validator-set")
	}
	if skipDeploy && validatorManagerImplementation != "" {
		return fmt.Errorf("--skip-deploy cannot be combined with --validator-manager-implementation")
	}
	if err := validateManagerType(managerType); err != nil {
		return err
	}
	// ValidatorManager.__ValidatorManager_init_unchained reverts on these, and
	// initializeSettings runs after the proxy upgrade, so a revert there leaves
	// an upgraded-but-uninitialized proxy. Reject the values up front.
	if maxChurnPercent == 0 || maxChurnPercent > 20 {
		return fmt.Errorf("--max-churn-percent must be between 1 and 20: ValidatorManager rejects 0 and MAXIMUM_CHURN_PERCENTAGE_LIMIT is 20")
	}
	if churnPeriod > 86400 {
		return fmt.Errorf("--churn-period must not exceed 86400 seconds: ValidatorManager MAXIMUM_CHURN_PERIOD_LENGTH is 1 day")
	}

	var (
		privKeyHex       string
		proxyAdminKeyHex string
		ownerAddress     string
		contractsPath    string
		err              error
	)
	if !preflightOnly {
		// Deployment credentials and contract tooling are deliberately not
		// required for the read-only preflight.
		privKeyHex, err = loadPrivateKey()
		if err != nil {
			return fmt.Errorf("failed to load private key: %w", err)
		}
		ownerAddress, err = getAddressFromPrivateKey(privKeyHex)
		if err != nil {
			return fmt.Errorf("failed to derive address: %w", err)
		}
		proxyAdminKeyHex, err = loadProxyAdminPrivateKey(privKeyHex)
		if err != nil {
			return fmt.Errorf("failed to load proxy admin private key: %w", err)
		}

		contractsPath = icmContractsPath
		if contractsPath == "" {
			contractsPath = os.Getenv("ICM_CONTRACTS_PATH")
		}
		if contractsPath == "" {
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
		if err := validateContractsPath(contractsPath, managerType); err != nil {
			return err
		}
		if _, err := exec.LookPath("forge"); err != nil {
			return fmt.Errorf("forge not found. Install foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup")
		}
	}

	ctx := context.Background()
	output.Proxy = proxyAddress

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
	if _, err := decodeEVMAddress(proxyAddress); err != nil {
		return fmt.Errorf("invalid proxy address: %w", err)
	}
	parsedNetworkID, err := avalancheNetworkID(networkName)
	if err != nil {
		return err
	}
	if !preflightOnly && !skipUpgrade {
		if err := validateProxyUpgradeAuthority(ctx, rpcURL, proxyAddress, proxyAdminKeyHex); err != nil {
			return fmt.Errorf("proxy upgrade authorization preflight failed: %w", err)
		}
	}

	// Fetch and validate the accepted conversion and obtain its signature before
	// deploying or changing any contract. This prevents a stale inventory, a
	// mismatched conversion, or an unavailable signature service from leaving a
	// partially initialized manager.
	var authoritativeConversion *AuthoritativeConversion
	var signedMessage []byte
	if !skipInitValSet {
		parsedConversionTxID, err := ids.FromString(conversionTxHash)
		if err != nil {
			return fmt.Errorf("invalid conversion transaction ID: %w", err)
		}

		nodeURL := pChainURL
		if nodeURL == "" {
			nodeURL, err = deriveAvalancheNodeURL(rpcURL)
			if err != nil {
				return fmt.Errorf("derive P-Chain API URL: %w", err)
			}
		}
		authoritativeConversion, err = fetchAuthoritativeConversion(
			ctx,
			nodeURL,
			parsedConversionTxID,
			parsedSubnetID,
			parsedChainID,
			proxyAddress,
		)
		if err != nil {
			return fmt.Errorf("validate accepted conversion transaction: %w", err)
		}
		authoritativeConversionID, err := authoritativeConversion.conversionID()
		if err != nil {
			return fmt.Errorf("derive accepted conversion ID: %w", err)
		}
		if conversionID != "" {
			expectedConversionID, err := parseID(conversionID)
			if err != nil {
				return fmt.Errorf("invalid --conversion-id %q: %w", conversionID, err)
			}
			if expectedConversionID != authoritativeConversionID {
				return fmt.Errorf(
					"--conversion-id mismatch: got %s, accepted transaction derives %s",
					expectedConversionID,
					authoritativeConversionID,
				)
			}
		}

		if !jsonOutput {
			fmt.Printf(
				"Preflight: accepted conversion contains %d initial validator(s), conversion ID %s\n",
				len(authoritativeConversion.Validators),
				authoritativeConversionID,
			)
		}
		if useLocalSigAgg {
			if !jsonOutput {
				fmt.Println("Preflight: fetching signature from local signature aggregator...")
			}
			signedMessage, err = getLocalAggregatedSignature(
				sigAggURL,
				parsedNetworkID,
				parsedSubnetID,
				authoritativeConversionID,
			)
		} else {
			apiKey := glacierAPIKey
			if apiKey == "" {
				apiKey = os.Getenv("GLACIER_API_KEY")
			}
			if !jsonOutput {
				fmt.Println("Preflight: fetching signature from Glacier API...")
			}
			signedMessage, err = waitForGlacierSignature(ctx, networkName, conversionTxHash, apiKey)
		}
		if err != nil {
			return fmt.Errorf("preflight signature acquisition failed: %w", err)
		}
		if err := validateSignedConversionMessage(signedMessage, parsedNetworkID, authoritativeConversionID); err != nil {
			return fmt.Errorf("preflight signature validation failed: %w", err)
		}
		if !jsonOutput {
			fmt.Printf("Preflight: signature validated (%d bytes)\n\n", len(signedMessage))
		}
	}
	if preflightOnly {
		if jsonOutput {
			jsonBytes, _ := json.MarshalIndent(Output{Proxy: proxyAddress, Success: true}, "", "  ")
			fmt.Println(string(jsonBytes))
		} else {
			fmt.Println("Preflight completed successfully; no contract state was changed.")
		}
		return nil
	}

	var implAddress string
	var libAddress string

	// Step 1: Deploy ValidatorManager implementation
	if !skipDeploy {
		if !jsonOutput {
			fmt.Println("[1/4] Deploying ValidatorManager implementation...")
		}

		if validatorManagerImplementation != "" {
			if err := validateDeployedContract(ctx, rpcURL, validatorManagerImplementation); err != nil {
				return fmt.Errorf("invalid existing ValidatorManager implementation: %w", err)
			}
			implAddress = validatorManagerImplementation
			if validatorMessagesLibrary != "" {
				if err := validateDeployedContract(ctx, rpcURL, validatorMessagesLibrary); err != nil {
					return fmt.Errorf("invalid existing ValidatorMessages library: %w", err)
				}
				libAddress = validatorMessagesLibrary
			}
		} else {
			implAddress, libAddress, err = deployImplementation(
				ctx,
				contractsPath,
				rpcURL,
				privKeyHex,
				managerType,
				validatorMessagesLibrary,
			)
			// deployImplementation returns the library address even when the
			// implementation deploy fails; record it before returning so a
			// resumed run can pass it back via --validator-messages-library.
			output.Library = libAddress
			if err != nil {
				return fmt.Errorf("failed to deploy implementation: %w", err)
			}
		}
		output.Implementation = implAddress
		output.Library = libAddress

		if !jsonOutput {
			fmt.Printf("  ValidatorMessages library: %s\n", libAddress)
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

		err = upgradeProxy(ctx, contractsPath, rpcURL, proxyAdminKeyHex, proxyAddress, implAddress)
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

		poaAddress, err := deployPoAManager(ctx, contractsPath, rpcURL, privKeyHex, ownerAddress, proxyAddress, libAddress)
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

		// Call initializeValidatorSet
		if !jsonOutput {
			fmt.Println("  Calling initializeValidatorSet...")
		}
		txHash, err := initializeValidatorSet(
			ctx,
			contractsPath,
			rpcURL,
			privKeyHex,
			proxyAddress,
			parsedSubnetID,
			parsedChainID,
			authoritativeConversion.Validators,
			signedMessage,
		)
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

	return normalizePrivateKey(keyStr), nil
}

func loadProxyAdminPrivateKey(defaultKey string) (string, error) {
	keyStr := strings.TrimSpace(os.Getenv("GENESIS_PROXY_ADMIN_PRIVATE_KEY"))
	if keyStr == "" {
		return defaultKey, nil
	}
	return normalizePrivateKey(keyStr), nil
}

func normalizePrivateKey(keyStr string) string {
	keyStr = strings.TrimPrefix(keyStr, "PrivateKey-")
	if !strings.HasPrefix(keyStr, "0x") {
		keyStr = "0x" + keyStr
	}
	return keyStr
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

	// The admin lives on the EVM chain: derive the Ethereum (keccak) address.
	// Address() would return the P-Chain ShortID in CB58, which cast rejects.
	return privKey.PublicKey().EthAddress().Hex(), nil
}

// validatorMessagesLibraryFlag returns the --libraries flag for linking ValidatorMessages.
func validatorMessagesLibraryFlag(libAddr string) string {
	return fmt.Sprintf("--libraries=contracts/validator-manager/ValidatorMessages.sol:ValidatorMessages:%s", libAddr)
}

func deployImplementation(ctx context.Context, contractsPath, rpcURL, privKey, managerType, existingLibAddr string) (implAddr string, libAddr string, err error) {
	// Resolve the implementation contract before deploying anything so an
	// unknown manager type fails without spending gas on the library.
	var contract string
	switch managerType {
	case "poa":
		contract = "contracts/validator-manager/ValidatorManager.sol:ValidatorManager"
	case "native-staking":
		contract = "contracts/validator-manager/NativeTokenStakingManager.sol:NativeTokenStakingManager"
	case "erc20-staking":
		contract = "contracts/validator-manager/ERC20TokenStakingManager.sol:ERC20TokenStakingManager"
	default:
		return "", "", fmt.Errorf("unknown manager type: %s", managerType)
	}

	// Deploy ValidatorMessages library first (required by all ValidatorManager variants).
	// Foundry no longer supports automatic dynamic linking in forge create.
	if existingLibAddr == "" {
		libAddr, err = forgeCreate(ctx, contractsPath, rpcURL, privKey,
			"contracts/validator-manager/ValidatorMessages.sol:ValidatorMessages")
		if err != nil {
			return "", "", fmt.Errorf("failed to deploy ValidatorMessages library: %w", err)
		}
	} else {
		if err := validateDeployedContract(ctx, rpcURL, existingLibAddr); err != nil {
			return "", "", fmt.Errorf("invalid existing ValidatorMessages library: %w", err)
		}
		libAddr = existingLibAddr
	}

	librariesFlag := validatorMessagesLibraryFlag(libAddr)

	// Deploy with ICMInitializable.Allowed = 0
	implAddr, err = forgeCreate(ctx, contractsPath, rpcURL, privKey, contract, librariesFlag, "--constructor-args", "0")
	return implAddr, libAddr, err
}

func upgradeProxy(ctx context.Context, contractsPath, rpcURL, privKey, proxyAddress, implAddress string) error {
	// The genesis ValidatorManager proxy is an OpenZeppelin (v4) TransparentUpgradeableProxy.
	// Its admin is a ProxyAdmin contract recorded in the EIP-1967 admin slot (e.g. 0xdad0...),
	// NOT the deployer EOA. Upgrades MUST go through ProxyAdmin.upgrade(proxy, impl). Calling
	// upgradeTo() directly on the proxy as a non-admin silently no-ops: the call falls through
	// to the (placeholder) implementation, the tx succeeds, but the proxy is never upgraded.
	adminAddr, err := proxyAdminAddress(ctx, rpcURL, proxyAddress)
	if err != nil {
		return err
	}
	_, err = castSend(ctx, rpcURL, privKey, adminAddr, "upgrade(address,address)", proxyAddress, implAddress)
	return err
}

func validateProxyUpgradeAuthority(ctx context.Context, rpcURL, proxyAddress, privKey string) error {
	adminAddr, err := proxyAdminAddress(ctx, rpcURL, proxyAddress)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, "cast", "call", adminAddr, "owner()(address)", "--rpc-url", rpcURL)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("read ProxyAdmin owner: %w\nOutput: %s", err, string(output))
	}
	actualOwner := strings.TrimSpace(string(output))
	configuredOwner, err := getAddressFromPrivateKey(privKey)
	if err != nil {
		return fmt.Errorf("derive configured ProxyAdmin key address: %w", err)
	}
	if !strings.EqualFold(actualOwner, configuredOwner) {
		return fmt.Errorf(
			"ProxyAdmin %s is owned by %s, but the configured key derives %s; set GENESIS_PROXY_ADMIN_PRIVATE_KEY to the ProxyAdmin owner key",
			adminAddr,
			actualOwner,
			configuredOwner,
		)
	}
	return nil
}

func proxyAdminAddress(ctx context.Context, rpcURL, proxyAddress string) (string, error) {
	const adminSlot = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
	raw, err := castStorage(ctx, rpcURL, proxyAddress, adminSlot)
	if err != nil {
		return "", fmt.Errorf("read proxy admin slot: %w", err)
	}
	raw = strings.TrimPrefix(strings.TrimSpace(raw), "0x")
	if len(raw) < 40 {
		return "", fmt.Errorf("unexpected proxy admin slot value %q (expected a 32-byte word)", raw)
	}
	return "0x" + raw[len(raw)-40:], nil
}

// castStorage reads a raw storage slot from a contract via `cast storage`.
func castStorage(ctx context.Context, rpcURL, addr, slot string) (string, error) {
	cmd := exec.CommandContext(ctx, "cast", "storage", addr, slot, "--rpc-url", rpcURL)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cast storage failed: %w\nOutput: %s", err, string(output))
	}
	return strings.TrimSpace(string(output)), nil
}

func initializeSettings(ctx context.Context, contractsPath, rpcURL, privKey, proxyAddress, admin, subnetIDHex string, churnPeriod uint64, maxChurn uint8) (string, error) {
	// function initialize(ValidatorManagerSettings calldata settings)
	// struct ValidatorManagerSettings { address admin; bytes32 subnetID; uint64 churnPeriodSeconds; uint8 maximumChurnPercentage; }

	settingsTuple := fmt.Sprintf("(%s,%s,%d,%d)", admin, subnetIDHex, churnPeriod, maxChurn)
	return castSend(ctx, rpcURL, privKey, proxyAddress, "initialize((address,bytes32,uint64,uint8))", settingsTuple)
}

func deployPoAManager(ctx context.Context, contractsPath, rpcURL, privKey, owner, validatorManager, libAddr string) (string, error) {
	// icm-contracts renamed PoAValidatorManager to PoAManager, a thin
	// Ownable wrapper around ValidatorManager that does not link
	// ValidatorMessages, so no --libraries flag is needed.
	_ = libAddr
	return forgeCreate(ctx, contractsPath, rpcURL, privKey,
		"contracts/validator-manager/PoAManager.sol:PoAManager",
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

func getLocalAggregatedSignature(sigAggURL string, networkID uint32, subnetID, conversionID ids.ID) ([]byte, error) {
	return BuildAndSignConversionMessageFromID(sigAggURL, networkID, subnetID, conversionID)
}

// parseID parses an Avalanche ID from cb58 or 0x-prefixed (or bare) 32-byte hex.
func parseID(s string) (ids.ID, error) {
	if strings.HasPrefix(s, "0x") || len(s) == 64 {
		b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
		if err != nil {
			return ids.Empty, err
		}
		return ids.ToID(b)
	}
	return ids.FromString(s)
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

	// The signed warp message is attached via the warp precompile predicate in the EIP-2930
	// access list. Predicate packing: append a 0xff delimiter, zero-pad to a 32-byte boundary,
	// then split into 32-byte storage keys. cast wants the access list as JSON. (cast produces a
	// type-2/DynamicFee tx, which is what the warp predicate verifier expects.)
	warpPrecompile := "0x0200000000000000000000000000000000000005"
	packed := append(append([]byte{}, signedMessage...), 0xff)
	for len(packed)%32 != 0 {
		packed = append(packed, 0x00)
	}
	storageKeys := make([]string, 0, len(packed)/32)
	for i := 0; i < len(packed); i += 32 {
		storageKeys = append(storageKeys, "0x"+hex.EncodeToString(packed[i:i+32]))
	}
	accessListJSON, err := json.Marshal([]map[string]interface{}{
		{"address": warpPrecompile, "storageKeys": storageKeys},
	})
	if err != nil {
		return "", fmt.Errorf("failed to build access list: %w", err)
	}

	cmd := exec.CommandContext(ctx, "cast", "send",
		"--rpc-url", rpcURL,
		"--private-key", privKey,
		"--json",
		"--access-list", string(accessListJSON),
		proxyAddress,
		"initializeValidatorSet((bytes32,bytes32,address,(bytes,bytes,uint64)[]),uint32)",
		conversionData, "0")

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cast send failed: %w\nOutput: %s", err, string(output))
	}

	txHash, err := parseCastSendOutput(output)
	if err != nil {
		// The signed warp transaction is already broadcast at this point. Returning
		// an error would fail the play after the validator set was initialized
		// on-chain, which also skips the l1.env persistence tasks.
		fmt.Fprintf(os.Stderr, "Warning: %v. Output: %s\n", err, string(output))
	}

	return txHash, nil
}

func forgeCreate(ctx context.Context, workDir, rpcURL, privKey, contract string, args ...string) (string, error) {
	// foundry 1.x made `forge create` a dry-run by default: without --broadcast
	// it only simulates, prints JSON without a deployedTo field, and exits 0,
	// which we'd otherwise misread as a successful deploy at the zero address.
	cmdArgs := []string{"create", "--broadcast", "--rpc-url", rpcURL, "--private-key", privKey, "--json", contract}
	cmdArgs = append(cmdArgs, args...)

	cmd := exec.CommandContext(ctx, "forge", cmdArgs...)
	cmd.Dir = workDir

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("forge create failed: %w\nOutput: %s", err, string(output))
	}

	deployedTo, err := parseForgeCreateOutput(output)
	if err != nil {
		return "", fmt.Errorf("%w. Output: %s", err, string(output))
	}

	return deployedTo, nil
}

func parseForgeCreateOutput(output []byte) (string, error) {
	type forgeCreateResult struct {
		DeployedTo string `json:"deployedTo"`
	}

	remaining := string(output)
	for {
		jsonStart := strings.IndexByte(remaining, '{')
		if jsonStart < 0 {
			break
		}

		var result forgeCreateResult
		decoder := json.NewDecoder(strings.NewReader(remaining[jsonStart:]))
		if err := decoder.Decode(&result); err == nil && result.DeployedTo != "" {
			return result.DeployedTo, nil
		}

		remaining = remaining[jsonStart+1:]
	}

	return "", fmt.Errorf("forge create returned no parseable deployedTo address")
}

// parseCastSendOutput extracts the transaction hash from `cast send --json`
// output, tolerating the foundry warnings that can precede the JSON. Failing
// here does not mean the transaction was not sent, so callers warn and keep the
// empty hash rather than failing after the transaction landed.
func parseCastSendOutput(output []byte) (string, error) {
	type castSendResult struct {
		TransactionHash string `json:"transactionHash"`
	}

	remaining := string(output)
	for {
		jsonStart := strings.IndexByte(remaining, '{')
		if jsonStart < 0 {
			break
		}

		var result castSendResult
		decoder := json.NewDecoder(strings.NewReader(remaining[jsonStart:]))
		if err := decoder.Decode(&result); err == nil && result.TransactionHash != "" {
			return result.TransactionHash, nil
		}

		remaining = remaining[jsonStart+1:]
	}

	return "", fmt.Errorf("cast send returned no parseable transactionHash")
}

func validateDeployedContract(ctx context.Context, rpcURL, address string) error {
	rawAddress := strings.TrimPrefix(address, "0x")
	if len(rawAddress) != 40 {
		return fmt.Errorf("address %q must contain 20 bytes", address)
	}
	if _, err := hex.DecodeString(rawAddress); err != nil {
		return fmt.Errorf("address %q is not valid hex: %w", address, err)
	}

	cmd := exec.CommandContext(ctx, "cast", "code", address, "--rpc-url", rpcURL)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("read contract code: %w\nOutput: %s", err, string(output))
	}
	code := strings.TrimSpace(string(output))
	if code == "" || code == "0x" || code == "0x0" {
		return fmt.Errorf("address %s has no deployed contract code", address)
	}
	return nil
}

func castSend(ctx context.Context, rpcURL, privKey, to, sig string, args ...string) (string, error) {
	cmdArgs := []string{"send", "--rpc-url", rpcURL, "--private-key", privKey, "--json", to, sig}
	cmdArgs = append(cmdArgs, args...)

	cmd := exec.CommandContext(ctx, "cast", cmdArgs...)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cast send failed: %w\nOutput: %s", err, string(output))
	}

	txHash, err := parseCastSendOutput(output)
	if err != nil {
		// cast exited 0, so the transaction was broadcast: only the reported hash
		// is missing. Failing here would abort the run after ProxyAdmin.upgrade(),
		// initialize() or transferOwnership() already changed on-chain state.
		fmt.Fprintf(os.Stderr, "Warning: %v. Output: %s\n", err, string(output))
	}

	return txHash, nil
}

func validateManagerType(value string) error {
	switch value {
	case "poa", "native-staking", "erc20-staking":
		return nil
	default:
		return fmt.Errorf("unknown manager type: %s", value)
	}
}

func validateContractsPath(contractsPath, selectedManagerType string) error {
	requiredFiles := []string{
		"foundry.toml",
		"contracts/validator-manager/ValidatorMessages.sol",
		"contracts/validator-manager/ValidatorManager.sol",
	}
	switch selectedManagerType {
	case "poa":
		requiredFiles = append(requiredFiles, "contracts/validator-manager/PoAManager.sol")
	case "native-staking":
		requiredFiles = append(requiredFiles, "contracts/validator-manager/NativeTokenStakingManager.sol")
	case "erc20-staking":
		requiredFiles = append(requiredFiles, "contracts/validator-manager/ERC20TokenStakingManager.sol")
	}

	for _, requiredFile := range requiredFiles {
		path := contractsPath + "/" + requiredFile
		info, err := os.Stat(path)
		if err != nil {
			if os.IsNotExist(err) {
				return fmt.Errorf("icm-contracts checkout is missing required file %s", path)
			}
			return fmt.Errorf("inspect required icm-contracts file %s: %w", path, err)
		}
		if info.IsDir() {
			return fmt.Errorf("required icm-contracts path is a directory: %s", path)
		}
	}
	return nil
}
