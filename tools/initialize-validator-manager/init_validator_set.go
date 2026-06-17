package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/api/info"
	"github.com/ava-labs/avalanchego/ids"
	avagoconstants "github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/message"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/payload"
	"github.com/ava-labs/libevm/accounts/abi"
	"github.com/ava-labs/libevm/common"
	"github.com/ava-labs/libevm/core/types"
	"github.com/ava-labs/libevm/crypto"
	"github.com/ava-labs/libevm/ethclient"
)

// ValidatorData holds validator information
type ValidatorData struct {
	NodeID       []byte
	BLSPublicKey []byte
	Weight       uint64
}

// InitialValidatorPayload for ABI encoding
type InitialValidatorPayload struct {
	NodeID       []byte
	BlsPublicKey []byte
	Weight       uint64
}

// SubnetConversionDataPayload for ABI encoding
type SubnetConversionDataPayload struct {
	SubnetID                     [32]byte
	ValidatorManagerBlockchainID [32]byte
	ValidatorManagerAddress      common.Address
	InitialValidators            []InitialValidatorPayload
}

// BuildWarpMessage constructs the unsigned warp message for validator set initialization
func BuildWarpMessage(networkID uint32, subnetID, chainID ids.ID, managerAddress common.Address, validators []ValidatorData) (*warp.UnsignedMessage, error) {
	// Build validator data for the message
	msgValidators := make([]message.SubnetToL1ConversionValidatorData, len(validators))
	for i, v := range validators {
		var blsKey [48]byte
		copy(blsKey[:], v.BLSPublicKey)
		msgValidators[i] = message.SubnetToL1ConversionValidatorData{
			NodeID:       v.NodeID,
			BLSPublicKey: blsKey,
			Weight:       v.Weight,
		}
	}

	// Build subnet conversion data
	subnetConversionData := message.SubnetToL1ConversionData{
		SubnetID:       subnetID,
		ManagerChainID: chainID,
		ManagerAddress: managerAddress.Bytes(),
		Validators:     msgValidators,
	}

	// Get conversion ID
	subnetConversionID, err := message.SubnetToL1ConversionID(subnetConversionData)
	if err != nil {
		return nil, fmt.Errorf("failed to create subnet conversion ID: %w", err)
	}

	fmt.Printf("  Subnet Conversion ID: %s\n", hex.EncodeToString(subnetConversionID[:]))

	// Create addressed call payload
	addressedCallPayload, err := message.NewSubnetToL1Conversion(subnetConversionID)
	if err != nil {
		return nil, fmt.Errorf("failed to create addressed call payload: %w", err)
	}

	// Wrap in AddressedCall (nil source for P-Chain)
	subnetConversionAddressedCall, err := payload.NewAddressedCall(
		nil,
		addressedCallPayload.Bytes(),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create addressed call: %w", err)
	}

	// Build unsigned warp message
	// Source chain is P-Chain for subnet conversion messages
	unsignedMessage, err := warp.NewUnsignedMessage(
		networkID,
		avagoconstants.PlatformChainID,
		subnetConversionAddressedCall.Bytes(),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create unsigned message: %w", err)
	}

	return unsignedMessage, nil
}

// GetValidatorInfo retrieves NodeID and BLS public key from a validator node
func GetValidatorInfo(nodeURL string) (ids.NodeID, []byte, error) {
	infoClient := info.NewClient(nodeURL)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	nodeID, pop, err := infoClient.GetNodeID(ctx)
	if err != nil {
		return ids.EmptyNodeID, nil, fmt.Errorf("failed to get node ID: %w", err)
	}

	return nodeID, pop.PublicKey[:], nil
}

// SignWarpMessageViaAggregator sends the unsigned message to a signature aggregator
// BuildAndSignConversionMessage builds the SubnetToL1Conversion warp message from the L1's
// conversion data (it derives the conversionID internally — this is NOT the ConvertSubnetToL1Tx
// hash) and aggregates a BLS signature from the L1's own validator set via a local
// signature-aggregator. Use this for private/custom L1s where Glacier cannot reach the
// validators (Glacier collects Primary-Network signatures; SubnetEVM verifies P-Chain-source
// messages against the L1's own validator set).
func BuildAndSignConversionMessage(sigAggURL string, networkID uint32, subnetID, chainID ids.ID, managerAddress string, validators []ValidatorData) ([]byte, error) {
	unsignedMsg, err := BuildWarpMessage(networkID, subnetID, chainID, common.HexToAddress(managerAddress), validators)
	if err != nil {
		return nil, fmt.Errorf("build SubnetToL1Conversion warp message: %w", err)
	}
	return SignWarpMessageViaAggregator(sigAggURL, unsignedMsg, subnetID)
}

// BuildAndSignConversionMessageFromID builds the SubnetToL1Conversion warp message from a known
// conversion ID (the on-chain hash of the conversion data) and aggregates a BLS signature from
// the L1's validator set. Prefer this over BuildAndSignConversionMessage when the conversion ID
// is known, since recomputing it from gathered validator data is fragile.
func BuildAndSignConversionMessageFromID(sigAggURL string, networkID uint32, subnetID, conversionID ids.ID) ([]byte, error) {
	addressedCallPayload, err := message.NewSubnetToL1Conversion(conversionID)
	if err != nil {
		return nil, fmt.Errorf("create SubnetToL1Conversion payload: %w", err)
	}
	addressedCall, err := payload.NewAddressedCall(nil, addressedCallPayload.Bytes())
	if err != nil {
		return nil, fmt.Errorf("create addressed call: %w", err)
	}
	unsignedMsg, err := warp.NewUnsignedMessage(networkID, avagoconstants.PlatformChainID, addressedCall.Bytes())
	if err != nil {
		return nil, fmt.Errorf("create unsigned message: %w", err)
	}
	return SignWarpMessageViaAggregator(sigAggURL, unsignedMsg, subnetID)
}

func SignWarpMessageViaAggregator(sigAggURL string, unsignedMsg *warp.UnsignedMessage, subnetID ids.ID) ([]byte, error) {
	// The signature aggregator expects hex-encoded unsigned message bytes
	msgHex := hex.EncodeToString(unsignedMsg.Bytes())

	// Justification is REQUIRED for P-Chain SubnetToL1Conversion messages: it is the subnet ID
	// bytes. Both signing-subnet-id and justification must be 0x-prefixed so the aggregator's
	// HexOrCB58ToID parses them as hex (a bare hex string is mis-read as cb58 and rejected).
	subnetHex := "0x" + hex.EncodeToString(subnetID[:])

	// Build request
	reqBody := fmt.Sprintf(`{"message":"%s","justification":"%s","signing-subnet-id":"%s","quorum-percentage":67}`,
		msgHex, subnetHex, subnetHex)

	fmt.Printf("  Requesting signature from aggregator...\n")
	fmt.Printf("  Message (first 100 chars): %s...\n", msgHex[:min(100, len(msgHex))])

	// Make HTTP request
	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Post(sigAggURL+"/aggregate-signatures", "application/json", strings.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("failed to call signature aggregator: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("signature aggregator returned status %d: %s", resp.StatusCode, string(body))
	}

	var result struct {
		SignedMessage string `json:"signed-message"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return hex.DecodeString(strings.TrimPrefix(result.SignedMessage, "0x"))
}

// SendInitializeValidatorSetTx sends the transaction with warp message in access list
func SendInitializeValidatorSetTx(
	rpcURL string,
	privateKeyHex string,
	managerAddress common.Address,
	subnetID, chainID ids.ID,
	validators []ValidatorData,
	signedWarpMessage []byte,
) (*types.Transaction, error) {
	// Connect to L1
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to L1: %w", err)
	}
	defer client.Close()

	// Parse private key
	privateKey, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}
	fromAddress := crypto.PubkeyToAddress(privateKey.PublicKey)

	// Build the ConversionData struct for the function call
	initialValidators := make([]InitialValidatorPayload, len(validators))
	for i, v := range validators {
		initialValidators[i] = InitialValidatorPayload{
			NodeID:       v.NodeID,
			BlsPublicKey: v.BLSPublicKey,
			Weight:       v.Weight,
		}
	}

	conversionData := SubnetConversionDataPayload{
		SubnetID:                     subnetID,
		ValidatorManagerBlockchainID: chainID,
		ValidatorManagerAddress:      managerAddress,
		InitialValidators:            initialValidators,
	}

	// Build ABI-encoded function call
	// initializeValidatorSet((bytes32,bytes32,address,(bytes,bytes,uint64)[]),uint32)
	abiDef := `[{"inputs":[{"components":[{"internalType":"bytes32","name":"subnetID","type":"bytes32"},{"internalType":"bytes32","name":"validatorManagerBlockchainID","type":"bytes32"},{"internalType":"address","name":"validatorManagerAddress","type":"address"},{"components":[{"internalType":"bytes","name":"nodeID","type":"bytes"},{"internalType":"bytes","name":"blsPublicKey","type":"bytes"},{"internalType":"uint64","name":"weight","type":"uint64"}],"internalType":"struct InitialValidator[]","name":"initialValidators","type":"tuple[]"}],"internalType":"struct ConversionData","name":"conversionData","type":"tuple"},{"internalType":"uint32","name":"messageIndex","type":"uint32"}],"name":"initializeValidatorSet","outputs":[],"stateMutability":"nonpayable","type":"function"}]`

	parsedABI, err := abi.JSON(strings.NewReader(abiDef))
	if err != nil {
		return nil, fmt.Errorf("failed to parse ABI: %w", err)
	}

	// Pack the function call
	callData, err := parsedABI.Pack("initializeValidatorSet", conversionData, uint32(0))
	if err != nil {
		return nil, fmt.Errorf("failed to pack function call: %w", err)
	}

	// Get nonce and gas price
	ctx := context.Background()
	nonce, err := client.PendingNonceAt(ctx, fromAddress)
	if err != nil {
		return nil, fmt.Errorf("failed to get nonce: %w", err)
	}

	gasPrice, err := client.SuggestGasPrice(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get gas price: %w", err)
	}

	chainIDInt, err := client.ChainID(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get chain ID: %w", err)
	}

	// Build access list with warp precompile
	warpPrecompile := common.HexToAddress("0x0200000000000000000000000000000000000005")

	// The warp message goes in the storage keys of the access list
	// Each 32-byte chunk of the message becomes a storage key
	storageKeys := make([]common.Hash, 0)

	// First key is the length prefix
	storageKeys = append(storageKeys, common.BytesToHash(signedWarpMessage))

	accessList := types.AccessList{
		{
			Address:     warpPrecompile,
			StorageKeys: storageKeys,
		},
	}

	// Estimate gas
	gasLimit := uint64(500000) // Start with a reasonable estimate

	// Create the transaction
	tx := types.NewTx(&types.AccessListTx{
		ChainID:    chainIDInt,
		Nonce:      nonce,
		GasPrice:   gasPrice,
		Gas:        gasLimit,
		To:         &managerAddress,
		Value:      big.NewInt(0),
		Data:       callData,
		AccessList: accessList,
	})

	// Sign the transaction
	signer := types.NewEIP2930Signer(chainIDInt)
	signedTx, err := types.SignTx(tx, signer, privateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to sign transaction: %w", err)
	}

	// Send the transaction
	if err := client.SendTransaction(ctx, signedTx); err != nil {
		return nil, fmt.Errorf("failed to send transaction: %w", err)
	}

	return signedTx, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
