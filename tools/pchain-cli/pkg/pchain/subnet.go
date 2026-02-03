// Package pchain provides P-Chain transaction utilities for Avalanche.
package pchain

import (
	"context"
	"fmt"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/vms/secp256k1fx"
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/wallet"
)

// CreateSubnet issues a CreateSubnetTx and returns the subnet ID.
func CreateSubnet(ctx context.Context, w *wallet.Wallet) (ids.ID, error) {
	owner := &secp256k1fx.OutputOwners{
		Threshold: 1,
		Addrs:     []ids.ShortID{w.OwnerAddress()},
	}

	subnetTx, err := w.PWallet().IssueCreateSubnetTx(owner)
	if err != nil {
		return ids.Empty, fmt.Errorf("failed to issue CreateSubnetTx: %w", err)
	}

	return subnetTx.ID(), nil
}
