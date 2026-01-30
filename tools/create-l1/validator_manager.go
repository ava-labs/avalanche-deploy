package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ava-labs/avalanchego/ids"
)

// ValidatorManagerType represents the type of validator manager to deploy
type ValidatorManagerType int

const (
	// PoAValidatorManagerType is for Proof of Authority L1s
	PoAValidatorManagerType ValidatorManagerType = iota
	// NativeTokenStakingManagerType is for PoS with native token staking
	NativeTokenStakingManagerType
	// ERC20TokenStakingManagerType is for PoS with ERC20 token staking
	ERC20TokenStakingManagerType
)

// ValidatorManagerDeployment contains addresses of deployed validator manager contracts
type ValidatorManagerDeployment struct {
	ValidatorManagerImpl  string `json:"validatorManagerImpl"`
	ValidatorManagerProxy string `json:"validatorManagerProxy"`
	ProxyAdmin            string `json:"proxyAdmin"`
	PoAManager            string `json:"poaManager,omitempty"`
	StakingManager        string `json:"stakingManager,omitempty"`
}

// DeployValidatorManagerWithForge deploys the validator manager contracts using forge
func DeployValidatorManagerWithForge(
	ctx context.Context,
	rpcURL string,
	privateKey string,
	subnetID ids.ID,
	ownerAddress string,
	managerType ValidatorManagerType,
	icmContractsPath string,
) (*ValidatorManagerDeployment, error) {
	// Check if forge is available
	if _, err := exec.LookPath("forge"); err != nil {
		return nil, fmt.Errorf("forge not found. Please install foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup")
	}

	// Determine the contracts path
	if icmContractsPath == "" {
		// Try common locations
		possiblePaths := []string{
			"../../../icm-services",
			"../../icm-services",
			os.Getenv("ICM_SERVICES_PATH"),
		}
		for _, p := range possiblePaths {
			if p != "" {
				foundryPath := filepath.Join(p, "foundry.toml")
				if _, err := os.Stat(foundryPath); err == nil {
					icmContractsPath = p
					break
				}
			}
		}
		if icmContractsPath == "" {
			return nil, fmt.Errorf("icm-services path not found. Set ICM_SERVICES_PATH or provide --contracts-path")
		}
	}

	fmt.Printf("  Using contracts from: %s\n", icmContractsPath)

	deployment := &ValidatorManagerDeployment{}

	// Step 1: Deploy ValidatorManager implementation
	fmt.Println("  Deploying ValidatorManager implementation...")
	vmImplAddr, err := forgeCreate(ctx, icmContractsPath, rpcURL, privateKey,
		"icm-contracts/avalanche/validator-manager/ValidatorManager.sol:ValidatorManager",
		"--constructor-args", "0") // ICMInitializable.Allowed = 0
	if err != nil {
		return nil, fmt.Errorf("failed to deploy ValidatorManager: %w", err)
	}
	deployment.ValidatorManagerImpl = vmImplAddr
	fmt.Printf("    Implementation: %s\n", vmImplAddr)

	// Step 2: Deploy TransparentUpgradeableProxy
	fmt.Println("  Deploying TransparentUpgradeableProxy...")
	// Initialize data is empty - we'll call initialize separately
	proxyAddr, err := forgeCreate(ctx, icmContractsPath, rpcURL, privateKey,
		"lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
		"--constructor-args", vmImplAddr, ownerAddress, "0x")
	if err != nil {
		// Try alternative path for OpenZeppelin contracts
		proxyAddr, err = forgeCreate(ctx, icmContractsPath, rpcURL, privateKey,
			"lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
			"--constructor-args", vmImplAddr, ownerAddress, "0x")
		if err != nil {
			return nil, fmt.Errorf("failed to deploy proxy: %w", err)
		}
	}
	deployment.ValidatorManagerProxy = proxyAddr
	deployment.ProxyAdmin = ownerAddress
	fmt.Printf("    Proxy: %s\n", proxyAddr)

	// Step 3: Initialize ValidatorManager
	fmt.Println("  Initializing ValidatorManager...")
	// Encode the settings struct for initialize call
	// ValidatorManagerSettings(address admin, bytes32 subnetID, uint64 churnPeriodSeconds, uint8 maximumChurnPercentage)
	subnetIDHex := "0x" + hex.EncodeToString(subnetID[:])
	initCalldata := encodeValidatorManagerInit(ownerAddress, subnetIDHex, 0, 20)

	_, err = forgeSend(ctx, icmContractsPath, rpcURL, privateKey, proxyAddr, initCalldata)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize ValidatorManager: %w", err)
	}
	fmt.Println("    ValidatorManager initialized")

	// Step 4: Deploy PoAManager
	switch managerType {
	case PoAValidatorManagerType:
		fmt.Println("  Deploying PoAManager...")
		poaAddr, err := forgeCreate(ctx, icmContractsPath, rpcURL, privateKey,
			"icm-contracts/avalanche/validator-manager/PoAManager.sol:PoAManager",
			"--constructor-args", ownerAddress, proxyAddr)
		if err != nil {
			return nil, fmt.Errorf("failed to deploy PoAManager: %w", err)
		}
		deployment.PoAManager = poaAddr
		fmt.Printf("    PoAManager: %s\n", poaAddr)

		// Step 5: Transfer ownership to PoAManager
		fmt.Println("  Transferring ValidatorManager ownership to PoAManager...")
		transferCalldata := encodeTransferOwnership(poaAddr)
		_, err = forgeSend(ctx, icmContractsPath, rpcURL, privateKey, proxyAddr, transferCalldata)
		if err != nil {
			return nil, fmt.Errorf("failed to transfer ownership: %w", err)
		}
		fmt.Println("    Ownership transferred")

	case NativeTokenStakingManagerType, ERC20TokenStakingManagerType:
		return nil, fmt.Errorf("staking manager deployment not yet implemented - use PoA for now")
	}

	return deployment, nil
}

// forgeCreate deploys a contract using forge create
func forgeCreate(ctx context.Context, workDir, rpcURL, privateKey, contract string, args ...string) (string, error) {
	cmdArgs := []string{
		"create",
		"--rpc-url", rpcURL,
		"--private-key", privateKey,
		"--json",
		contract,
	}
	cmdArgs = append(cmdArgs, args...)

	cmd := exec.CommandContext(ctx, "forge", cmdArgs...)
	cmd.Dir = workDir

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("forge create failed: %w\nOutput: %s", err, string(output))
	}

	// Parse JSON output to get deployed address
	var result struct {
		DeployedTo string `json:"deployedTo"`
	}
	if err := json.Unmarshal(output, &result); err != nil {
		// Try to extract address from non-JSON output
		lines := strings.Split(string(output), "\n")
		for _, line := range lines {
			if strings.Contains(line, "Deployed to:") {
				parts := strings.Split(line, ":")
				if len(parts) >= 2 {
					return strings.TrimSpace(parts[1]), nil
				}
			}
		}
		return "", fmt.Errorf("failed to parse forge output: %w\nOutput: %s", err, string(output))
	}

	return result.DeployedTo, nil
}

// forgeSend sends a transaction using cast
func forgeSend(ctx context.Context, workDir, rpcURL, privateKey, to, calldata string) (string, error) {
	cmd := exec.CommandContext(ctx, "cast", "send",
		"--rpc-url", rpcURL,
		"--private-key", privateKey,
		"--json",
		to,
		calldata,
	)
	cmd.Dir = workDir

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cast send failed: %w\nOutput: %s", err, string(output))
	}

	return string(output), nil
}

// encodeValidatorManagerInit encodes the initialize call for ValidatorManager
func encodeValidatorManagerInit(admin, subnetID string, churnPeriodSeconds uint64, maxChurnPercentage uint8) string {
	// function initialize(ValidatorManagerSettings calldata settings)
	// struct ValidatorManagerSettings { address admin; bytes32 subnetID; uint64 churnPeriodSeconds; uint8 maximumChurnPercentage; }
	// For now, use cast to encode the call
	// cast calldata "initialize((address,bytes32,uint64,uint8))" "(admin,subnetID,0,20)"
	return fmt.Sprintf("initialize((address,bytes32,uint64,uint8)) (%s,%s,%d,%d)",
		admin, subnetID, churnPeriodSeconds, maxChurnPercentage)
}

// encodeTransferOwnership encodes the transferOwnership call
func encodeTransferOwnership(newOwner string) string {
	return fmt.Sprintf("transferOwnership(address) %s", newOwner)
}

// SaveDeployment saves the deployment info to a JSON file
func (d *ValidatorManagerDeployment) SaveDeployment(filepath string) error {
	data, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath, data, 0644)
}

// LoadDeployment loads deployment info from a JSON file
func LoadDeployment(filepath string) (*ValidatorManagerDeployment, error) {
	data, err := os.ReadFile(filepath)
	if err != nil {
		return nil, err
	}
	var d ValidatorManagerDeployment
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, err
	}
	return &d, nil
}

// GetManagerAddressForConversion returns the manager address bytes for ConvertSubnetToL1Tx
func (d *ValidatorManagerDeployment) GetManagerAddressForConversion() ([]byte, error) {
	addr := d.ValidatorManagerProxy
	if addr == "" {
		return nil, fmt.Errorf("no validator manager proxy address")
	}
	addr = strings.TrimPrefix(addr, "0x")
	return hex.DecodeString(addr)
}
