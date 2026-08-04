package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/vms/platformvm"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp"
	warpmessage "github.com/ava-labs/avalanchego/vms/platformvm/warp/message"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/payload"
)

// AuthoritativeConversion contains only the conversion data committed by the
// accepted ConvertSubnetToL1Tx. Inventory membership is intentionally not part
// of this structure because inventory may contain validators that will be added
// after the initial conversion.
type AuthoritativeConversion struct {
	SubnetID       ids.ID
	ChainID        ids.ID
	ManagerAddress []byte
	Validators     []ValidatorInfo
}

func deriveAvalancheNodeURL(l1RPCURL string) (string, error) {
	parsed, err := url.Parse(l1RPCURL)
	if err != nil {
		return "", fmt.Errorf("parse L1 RPC URL: %w", err)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("L1 RPC URL must use http or https")
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("L1 RPC URL is missing a host")
	}

	parsed.Path = ""
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return strings.TrimRight(parsed.String(), "/"), nil
}

func fetchAuthoritativeConversion(
	ctx context.Context,
	nodeURL string,
	conversionTxID ids.ID,
	expectedSubnetID ids.ID,
	expectedChainID ids.ID,
	expectedManagerAddress string,
) (*AuthoritativeConversion, error) {
	// avalanchego's platformvm client uses http.DefaultClient, which has no
	// timeout: a node that accepts the connection but never answers would hang
	// the tool forever. Bound it like the other API calls in this tool.
	requestCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	txBytes, err := platformvm.NewClient(strings.TrimRight(nodeURL, "/")).GetTx(requestCtx, conversionTxID)
	if err != nil {
		return nil, fmt.Errorf("fetch ConvertSubnetToL1Tx %s from %s/ext/P: %w", conversionTxID, strings.TrimRight(nodeURL, "/"), err)
	}

	tx, err := txs.Parse(txs.Codec, txBytes)
	if err != nil {
		return nil, fmt.Errorf("parse ConvertSubnetToL1Tx %s: %w", conversionTxID, err)
	}
	if tx.ID() != conversionTxID {
		return nil, fmt.Errorf("P-Chain returned transaction %s when %s was requested", tx.ID(), conversionTxID)
	}

	return extractAuthoritativeConversion(tx, expectedSubnetID, expectedChainID, expectedManagerAddress)
}

func extractAuthoritativeConversion(
	tx *txs.Tx,
	expectedSubnetID ids.ID,
	expectedChainID ids.ID,
	expectedManagerAddress string,
) (*AuthoritativeConversion, error) {
	if tx == nil {
		return nil, fmt.Errorf("conversion transaction is nil")
	}

	conversionTx, ok := tx.Unsigned.(*txs.ConvertSubnetToL1Tx)
	if !ok {
		return nil, fmt.Errorf("transaction is %T, expected *txs.ConvertSubnetToL1Tx", tx.Unsigned)
	}
	if conversionTx.Subnet != expectedSubnetID {
		return nil, fmt.Errorf("conversion subnet mismatch: transaction has %s, expected %s", conversionTx.Subnet, expectedSubnetID)
	}
	if conversionTx.ChainID != expectedChainID {
		return nil, fmt.Errorf("conversion blockchain mismatch: transaction has %s, expected %s", conversionTx.ChainID, expectedChainID)
	}

	expectedAddress, err := decodeEVMAddress(expectedManagerAddress)
	if err != nil {
		return nil, fmt.Errorf("invalid manager/proxy address: %w", err)
	}
	if !bytes.Equal(conversionTx.Address, expectedAddress) {
		return nil, fmt.Errorf(
			"conversion manager address mismatch: transaction has 0x%s, expected 0x%s",
			hex.EncodeToString(conversionTx.Address),
			hex.EncodeToString(expectedAddress),
		)
	}
	if len(conversionTx.Validators) == 0 {
		return nil, fmt.Errorf("conversion transaction has no initial validators")
	}

	validators := make([]ValidatorInfo, len(conversionTx.Validators))
	for i, validator := range conversionTx.Validators {
		if validator == nil {
			return nil, fmt.Errorf("conversion validator %d is nil", i)
		}
		nodeID, err := ids.ToNodeID(validator.NodeID)
		if err != nil {
			return nil, fmt.Errorf("conversion validator %d has invalid node ID: %w", i, err)
		}
		publicKey := make([]byte, len(validator.Signer.PublicKey))
		copy(publicKey, validator.Signer.PublicKey[:])
		validators[i] = ValidatorInfo{
			NodeID:    nodeID,
			PublicKey: publicKey,
			Weight:    validator.Weight,
		}
	}

	managerAddress := make([]byte, len(conversionTx.Address))
	copy(managerAddress, conversionTx.Address)
	return &AuthoritativeConversion{
		SubnetID:       conversionTx.Subnet,
		ChainID:        conversionTx.ChainID,
		ManagerAddress: managerAddress,
		Validators:     validators,
	}, nil
}

func decodeEVMAddress(address string) ([]byte, error) {
	trimmed := strings.TrimPrefix(strings.TrimSpace(address), "0x")
	if len(trimmed) != 40 {
		return nil, fmt.Errorf("expected 20-byte hex address, got %d hex characters", len(trimmed))
	}
	decoded, err := hex.DecodeString(trimmed)
	if err != nil {
		return nil, fmt.Errorf("decode hex address: %w", err)
	}
	return decoded, nil
}

func (conversion *AuthoritativeConversion) conversionID() (ids.ID, error) {
	validators := make([]warpmessage.SubnetToL1ConversionValidatorData, len(conversion.Validators))
	for i, validator := range conversion.Validators {
		if len(validator.PublicKey) != len(validators[i].BLSPublicKey) {
			return ids.Empty, fmt.Errorf(
				"conversion validator %s has invalid BLS public key length %d",
				validator.NodeID,
				len(validator.PublicKey),
			)
		}
		copy(validators[i].BLSPublicKey[:], validator.PublicKey)
		validators[i].NodeID = append([]byte(nil), validator.NodeID[:]...)
		validators[i].Weight = validator.Weight
	}

	return warpmessage.SubnetToL1ConversionID(warpmessage.SubnetToL1ConversionData{
		SubnetID:       conversion.SubnetID,
		ManagerChainID: conversion.ChainID,
		ManagerAddress: append([]byte(nil), conversion.ManagerAddress...),
		Validators:     validators,
	})
}

func validateSignedConversionMessage(signedMessage []byte, networkID uint32, expectedConversionID ids.ID) error {
	parsedMessage, err := warp.ParseMessage(signedMessage)
	if err != nil {
		return fmt.Errorf("parse signed Warp message: %w", err)
	}
	if parsedMessage.NetworkID != networkID {
		return fmt.Errorf("signed Warp message network mismatch: got %d, expected %d", parsedMessage.NetworkID, networkID)
	}
	if parsedMessage.SourceChainID != constants.PlatformChainID {
		return fmt.Errorf(
			"signed Warp message source chain mismatch: got %s, expected P-Chain %s",
			parsedMessage.SourceChainID,
			constants.PlatformChainID,
		)
	}

	addressedCall, err := payload.ParseAddressedCall(parsedMessage.Payload)
	if err != nil {
		return fmt.Errorf("parse signed Warp addressed call: %w", err)
	}
	if len(addressedCall.SourceAddress) != 0 {
		return fmt.Errorf("signed conversion message has an unexpected source address")
	}
	conversionMessage, err := warpmessage.ParseSubnetToL1Conversion(addressedCall.Payload)
	if err != nil {
		return fmt.Errorf("parse SubnetToL1Conversion message: %w", err)
	}
	if conversionMessage.ID != expectedConversionID {
		return fmt.Errorf(
			"signed conversion ID mismatch: got %s, expected %s",
			conversionMessage.ID,
			expectedConversionID,
		)
	}
	return nil
}

func avalancheNetworkID(network string) (uint32, error) {
	switch network {
	case "mainnet":
		return constants.MainnetID, nil
	case "fuji", "testnet":
		return constants.FujiID, nil
	default:
		return 0, fmt.Errorf("unsupported network %q (expected fuji, testnet, or mainnet)", network)
	}
}
