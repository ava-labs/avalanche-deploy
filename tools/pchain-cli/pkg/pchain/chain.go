package pchain

import (
	"context"
	"fmt"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/wallet"
)

// ChainConfig holds configuration for creating a chain.
type ChainConfig struct {
	SubnetID     string
	GenesisBytes []byte
	ChainName    string
}

// CreateChain issues a CreateChainTx and returns the chain ID.
func CreateChain(ctx context.Context, w *wallet.Wallet, config ChainConfig) (ids.ID, error) {
	subnetID, err := ids.FromString(config.SubnetID)
	if err != nil {
		return ids.Empty, fmt.Errorf("invalid subnet ID: %w", err)
	}

	// Validate chain name
	if err := ValidateChainName(config.ChainName); err != nil {
		return ids.Empty, err
	}

	chainTx, err := w.PWallet().IssueCreateChainTx(
		subnetID,
		config.GenesisBytes,
		constants.SubnetEVMID,
		nil, // no fx IDs
		config.ChainName,
	)
	if err != nil {
		return ids.Empty, fmt.Errorf("failed to issue CreateChainTx: %w", err)
	}

	return chainTx.ID(), nil
}

// ValidateChainName checks that the chain name contains only alphanumeric characters.
// Avalanche P-Chain rejects chain names with hyphens, spaces, or special characters.
func ValidateChainName(name string) error {
	if name == "" {
		return fmt.Errorf("chain name cannot be empty")
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			return fmt.Errorf("invalid chain name %q: must contain only alphanumeric characters (a-z, A-Z, 0-9). Got invalid character %q", name, string(c))
		}
	}
	return nil
}
