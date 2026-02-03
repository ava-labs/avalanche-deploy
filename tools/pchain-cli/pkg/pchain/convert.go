package pchain

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/ava-labs/avalanchego/api/info"
	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/units"
	"github.com/ava-labs/avalanchego/vms/platformvm/signer"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/wallet"
)

// ConvertConfig holds configuration for converting a subnet to L1.
type ConvertConfig struct {
	SubnetID         string
	ChainID          string
	ManagerAddress   string  // Optional validator manager address
	ValidatorIPs     string  // Comma-separated validator IPs
	ValidatorBalance float64 // Balance per validator in AVAX
}

// ValidatorInfo holds information about a validator node.
type ValidatorInfo struct {
	NodeID ids.NodeID
	PoP    *signer.ProofOfPossession
	Weight uint64
}

// ConvertSubnetToL1 issues a ConvertSubnetToL1Tx and returns the transaction ID.
func ConvertSubnetToL1(ctx context.Context, w *wallet.Wallet, config ConvertConfig) (ids.ID, error) {
	subnetID, err := ids.FromString(config.SubnetID)
	if err != nil {
		return ids.Empty, fmt.Errorf("invalid subnet ID: %w", err)
	}

	chainID, err := ids.FromString(config.ChainID)
	if err != nil {
		return ids.Empty, fmt.Errorf("invalid chain ID: %w", err)
	}

	// Parse manager address
	var managerAddress []byte
	if config.ManagerAddress != "" {
		addrStr := strings.TrimPrefix(config.ManagerAddress, "0x")
		if len(addrStr) != 40 {
			return ids.Empty, fmt.Errorf("invalid manager address: expected 40 hex chars")
		}
		managerAddress, err = hex.DecodeString(addrStr)
		if err != nil {
			return ids.Empty, fmt.Errorf("failed to decode manager address: %w", err)
		}
	}

	// Get validator info
	validators, err := gatherValidatorInfo(ctx, config.ValidatorIPs, config.ValidatorBalance)
	if err != nil {
		return ids.Empty, fmt.Errorf("failed to gather validator info: %w", err)
	}

	// Build conversion validators
	conversionValidators := make([]*txs.ConvertSubnetToL1Validator, 0, len(validators))
	for _, v := range validators {
		conversionValidators = append(conversionValidators, &txs.ConvertSubnetToL1Validator{
			NodeID:  v.NodeID.Bytes(),
			Weight:  v.Weight,
			Balance: uint64(config.ValidatorBalance * float64(units.Avax)),
			Signer:  *v.PoP,
		})
	}

	conversionTx, err := w.PWallet().IssueConvertSubnetToL1Tx(
		subnetID,
		chainID,
		managerAddress,
		conversionValidators,
	)
	if err != nil {
		return ids.Empty, fmt.Errorf("failed to issue ConvertSubnetToL1Tx: %w", err)
	}

	return conversionTx.ID(), nil
}

// gatherValidatorInfo queries validator nodes for their NodeID and BLS key.
func gatherValidatorInfo(ctx context.Context, validatorIPs string, balance float64) ([]ValidatorInfo, error) {
	ips := parseIPs(validatorIPs)
	if len(ips) == 0 {
		return nil, fmt.Errorf("no validator IPs provided")
	}

	validators := make([]ValidatorInfo, 0, len(ips))

	for _, ip := range ips {
		uri := fmt.Sprintf("http://%s:9650", ip)
		infoClient := info.NewClient(uri)

		nodeID, nodePoP, err := infoClient.GetNodeID(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to get node info from %s: %w", uri, err)
		}

		validators = append(validators, ValidatorInfo{
			NodeID: nodeID,
			PoP:    nodePoP,
			Weight: units.Schmeckle,
		})
	}

	return validators, nil
}

// parseIPs parses a comma-separated list of IPs.
func parseIPs(ipList string) []string {
	var ips []string
	for _, ip := range strings.Split(ipList, ",") {
		ip = strings.TrimSpace(ip)
		if ip != "" {
			ips = append(ips, ip)
		}
	}
	return ips
}
