// Package node provides utilities for querying Avalanche node information.
package node

import (
	"context"
	"encoding/hex"
	"fmt"

	"github.com/ava-labs/avalanchego/api/info"
)

// NodeInfo holds information about an Avalanche node.
type NodeInfo struct {
	NodeID               string
	BLSPublicKey         string
	BLSProofOfPossession string
}

// GetNodeInfo queries an avalanchego node for its node ID and BLS key.
func GetNodeInfo(ctx context.Context, ip string) (*NodeInfo, error) {
	uri := fmt.Sprintf("http://%s:9650", ip)
	infoClient := info.NewClient(uri)

	nodeID, nodePoP, err := infoClient.GetNodeID(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get node info from %s: %w", uri, err)
	}

	blsPubKey := ""
	blsPoP := ""
	if nodePoP != nil {
		blsPubKey = hex.EncodeToString(nodePoP.PublicKey[:])
		blsPoP = hex.EncodeToString(nodePoP.ProofOfPossession[:])
	}

	return &NodeInfo{
		NodeID:               nodeID.String(),
		BLSPublicKey:         blsPubKey,
		BLSProofOfPossession: blsPoP,
	}, nil
}

// GetNodeIDs queries multiple nodes and returns their NodeIDs.
func GetNodeIDs(ctx context.Context, ips []string) ([]string, error) {
	nodeIDs := make([]string, 0, len(ips))

	for _, ip := range ips {
		info, err := GetNodeInfo(ctx, ip)
		if err != nil {
			return nil, err
		}
		nodeIDs = append(nodeIDs, info.NodeID)
	}

	return nodeIDs, nil
}
