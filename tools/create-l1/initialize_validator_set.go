package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/crypto/bls"
	"github.com/ava-labs/avalanchego/vms/platformvm/signer"
)

// GlacierSignatureResponse is the response from the Glacier signature aggregator API
type GlacierSignatureResponse struct {
	SignedMessage string `json:"signedMessage"`
}

// InitialValidator represents a validator for the conversion data
type InitialValidator struct {
	NodeID       []byte
	BlsPublicKey []byte
	Weight       uint64
}

// ConversionData represents the data needed for initializeValidatorSet
type ConversionData struct {
	SubnetID                     ids.ID
	ValidatorManagerBlockchainID ids.ID
	ValidatorManagerAddress      string
	InitialValidators            []InitialValidator
}

// GetAggregatedSignature fetches the aggregated warp message signature from Glacier API
func GetAggregatedSignature(ctx context.Context, network string, txHash string, apiKey string) ([]byte, error) {
	// Map network names
	glacierNetwork := network
	if network == "fuji" {
		glacierNetwork = "testnet"
	}

	url := fmt.Sprintf("https://data-api.avax.network/v1/signatureAggregator/%s/aggregateSignatures/%s",
		glacierNetwork, txHash)

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	if apiKey != "" {
		req.Header.Set("x-glacier-api-key", apiKey)
	}

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to call Glacier API: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return nil, fmt.Errorf("Glacier API error (status %d): %s", resp.StatusCode, string(body))
	}

	var result GlacierSignatureResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	// Decode the hex-encoded signed message
	signedMessage := strings.TrimPrefix(result.SignedMessage, "0x")
	return hex.DecodeString(signedMessage)
}

// WaitForAggregatedSignature polls the Glacier API until the signature is available
func WaitForAggregatedSignature(ctx context.Context, network string, txHash string, apiKey string, maxRetries int) ([]byte, error) {
	var lastErr error

	for i := 0; i < maxRetries; i++ {
		sig, err := GetAggregatedSignature(ctx, network, txHash, apiKey)
		if err == nil {
			return sig, nil
		}
		lastErr = err

		// Check if context is cancelled
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		// Wait before retrying
		fmt.Printf("    Waiting for signature aggregation (attempt %d/%d)...\n", i+1, maxRetries)
		time.Sleep(10 * time.Second)
	}

	return nil, fmt.Errorf("failed to get aggregated signature after %d attempts: %w", maxRetries, lastErr)
}

// InitializeValidatorSet calls initializeValidatorSet on the ValidatorManager contract
func InitializeValidatorSet(
	ctx context.Context,
	rpcURL string,
	privateKey string,
	validatorManagerProxy string,
	conversionData ConversionData,
	signedWarpMessage []byte,
	contractsPath string,
) error {
	// Encode the ConversionData struct for the contract call
	// struct ConversionData {
	//   bytes32 subnetID;
	//   bytes32 validatorManagerBlockchainID;
	//   address validatorManagerAddress;
	//   InitialValidator[] initialValidators;
	// }
	// struct InitialValidator {
	//   bytes nodeID;
	//   bytes blsPublicKey;
	//   uint64 weight;
	// }

	// Build the initialValidators array encoding
	validatorsEncoded := make([]string, len(conversionData.InitialValidators))
	for i, v := range conversionData.InitialValidators {
		validatorsEncoded[i] = fmt.Sprintf("(0x%s,0x%s,%d)",
			hex.EncodeToString(v.NodeID),
			hex.EncodeToString(v.BlsPublicKey),
			v.Weight,
		)
	}
	validatorsArray := "[" + strings.Join(validatorsEncoded, ",") + "]"

	// Build the ConversionData tuple
	conversionDataEncoded := fmt.Sprintf("(0x%s,0x%s,%s,%s)",
		hex.EncodeToString(conversionData.SubnetID[:]),
		hex.EncodeToString(conversionData.ValidatorManagerBlockchainID[:]),
		conversionData.ValidatorManagerAddress,
		validatorsArray,
	)

	// The messageIndex is 0 for the initial conversion
	messageIndex := uint32(0)

	// Use cast to send the transaction with the warp message in the access list
	// The warp message needs to be included in the transaction's access list
	// at the warp precompile address (0x0200000000000000000000000000000000000005)
	warpPrecompile := "0x0200000000000000000000000000000000000005"
	warpMessageHex := "0x" + hex.EncodeToString(signedWarpMessage)

	// Build the function call
	functionSig := "initializeValidatorSet((bytes32,bytes32,address,(bytes,bytes,uint64)[]),uint32)"
	callArgs := fmt.Sprintf("%s %d", conversionDataEncoded, messageIndex)

	// Use cast with access-list for the warp message
	cmd := exec.CommandContext(ctx, "cast", "send",
		"--rpc-url", rpcURL,
		"--private-key", privateKey,
		"--json",
		"--access-list", fmt.Sprintf("%s:%s", warpPrecompile, warpMessageHex),
		validatorManagerProxy,
		functionSig,
		callArgs,
	)

	if contractsPath != "" {
		cmd.Dir = contractsPath
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to call initializeValidatorSet: %w\nOutput: %s", err, string(output))
	}

	// Parse the response to check success
	var result struct {
		Status string `json:"status"`
		TxHash string `json:"transactionHash"`
	}
	if err := json.Unmarshal(output, &result); err == nil {
		if result.Status == "0x1" || result.Status == "1" {
			fmt.Printf("    initializeValidatorSet succeeded: %s\n", result.TxHash)
			return nil
		}
	}

	// If we can't parse as JSON, check for success in the output
	if strings.Contains(string(output), "success") || strings.Contains(string(output), "0x1") {
		return nil
	}

	return fmt.Errorf("initializeValidatorSet may have failed. Output: %s", string(output))
}

// BuildConversionData constructs the ConversionData from validator info
func BuildConversionData(
	subnetID ids.ID,
	chainID ids.ID,
	validatorManagerAddress string,
	nodeIDs []ids.NodeID,
	nodePoPs []*signer.ProofOfPossession,
	weights []uint64,
) ConversionData {
	validators := make([]InitialValidator, len(nodeIDs))
	for i := range nodeIDs {
		validators[i] = InitialValidator{
			NodeID:       nodeIDs[i].Bytes(),
			BlsPublicKey: nodePoPs[i].PublicKey[:],
			Weight:       weights[i],
		}
	}

	return ConversionData{
		SubnetID:                     subnetID,
		ValidatorManagerBlockchainID: chainID,
		ValidatorManagerAddress:      validatorManagerAddress,
		InitialValidators:            validators,
	}
}

// InitializeValidatorSetWithGlacier is a convenience function that:
// 1. Waits for the aggregated signature from Glacier
// 2. Calls initializeValidatorSet on the contract
func InitializeValidatorSetWithGlacier(
	ctx context.Context,
	network string,
	conversionTxHash string,
	chainRPCURL string,
	privateKey string,
	validatorManagerProxy string,
	conversionData ConversionData,
	contractsPath string,
	glacierAPIKey string,
) error {
	fmt.Println("  Fetching aggregated signature from Glacier API...")

	// Wait for signature aggregation (may take a few blocks)
	signedMessage, err := WaitForAggregatedSignature(ctx, network, conversionTxHash, glacierAPIKey, 30)
	if err != nil {
		return fmt.Errorf("failed to get aggregated signature: %w", err)
	}
	fmt.Printf("    Signature received (%d bytes)\n", len(signedMessage))

	fmt.Println("  Calling initializeValidatorSet...")
	return InitializeValidatorSet(
		ctx,
		chainRPCURL,
		privateKey,
		validatorManagerProxy,
		conversionData,
		signedMessage,
		contractsPath,
	)
}

// BuildSubnetToL1ConversionMessage builds the unsigned warp message for subnet conversion
// Returns the unsigned message bytes and justification bytes
func BuildSubnetToL1ConversionMessage(
	networkID uint32,
	subnetID ids.ID,
	chainID ids.ID,
	validatorManagerAddress string,
	nodeIDs []ids.NodeID,
	nodePoPs []*signer.ProofOfPossession,
	weights []uint64,
) ([]byte, []byte, error) {
	// Build the ConversionData
	conversionData := ConversionData{
		SubnetID:                     subnetID,
		ValidatorManagerBlockchainID: chainID,
		ValidatorManagerAddress:      validatorManagerAddress,
		InitialValidators:            make([]InitialValidator, len(nodeIDs)),
	}
	for i := range nodeIDs {
		conversionData.InitialValidators[i] = InitialValidator{
			NodeID:       nodeIDs[i].Bytes(),
			BlsPublicKey: nodePoPs[i].PublicKey[:],
			Weight:       weights[i],
		}
	}

	// Calculate the conversionID
	conversionID, err := CalculateConversionID(conversionData)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to calculate conversionID: %w", err)
	}

	// Build the SubnetToL1ConversionMessage payload
	// This is: codecID (2) + typeID (4) + conversionID (32) = 38 bytes
	payload := make([]byte, 38)
	// codecID = 0
	payload[0] = 0
	payload[1] = 0
	// typeID = 0 (SUBNET_TO_L1_CONVERSION_MESSAGE_TYPE_ID)
	payload[2] = 0
	payload[3] = 0
	payload[4] = 0
	payload[5] = 0
	// conversionID
	copy(payload[6:38], conversionID[:])

	// Build the AddressedCall payload
	// sourceAddress length (4 bytes) = 0 (nil source)
	// sourceAddress = empty
	// payload
	addressedCall := make([]byte, 4+len(payload))
	// sourceAddress length = 0
	addressedCall[0] = 0
	addressedCall[1] = 0
	addressedCall[2] = 0
	addressedCall[3] = 0
	copy(addressedCall[4:], payload)

	// Build the unsigned warp message
	// networkID (4) + sourceChainID (32) + payload
	unsignedMsg := make([]byte, 4+32+len(addressedCall))
	unsignedMsg[0] = byte(networkID >> 24)
	unsignedMsg[1] = byte(networkID >> 16)
	unsignedMsg[2] = byte(networkID >> 8)
	unsignedMsg[3] = byte(networkID)
	// P-Chain ID is all zeros for primary network
	// Actually for warp messages from P-Chain, we use the P-Chain's blockchain ID
	// which is 11111111111111111111111111111111LpoYY (the primary network's P-Chain)
	pChainID := ids.Empty // Primary network P-Chain
	copy(unsignedMsg[4:36], pChainID[:])
	copy(unsignedMsg[36:], addressedCall)

	// Justification is the subnetID for conversion messages
	justification := subnetID[:]

	return unsignedMsg, justification, nil
}

// CallLocalSignatureAggregatorWithRetry calls a local signature-aggregator with retries
func CallLocalSignatureAggregatorWithRetry(
	ctx context.Context,
	url string,
	unsignedMessage []byte,
	justification []byte,
	signingSubnetID ids.ID,
	quorumPercentage int,
	maxRetries int,
) ([]byte, error) {
	var lastErr error

	for i := 0; i < maxRetries; i++ {
		sig, err := CallLocalSignatureAggregator(ctx, url, unsignedMessage, justification, signingSubnetID, quorumPercentage)
		if err == nil {
			return sig, nil
		}
		lastErr = err

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		if i < maxRetries-1 {
			fmt.Printf("    Retry %d/%d: %v\n", i+1, maxRetries, err)
			time.Sleep(5 * time.Second)
		}
	}

	return nil, fmt.Errorf("failed after %d attempts: %w", maxRetries, lastErr)
}

// CalculateConversionID computes the conversionID from ConversionData
// This matches the P-Chain's calculation and the contract's verification
func CalculateConversionID(data ConversionData) (ids.ID, error) {
	// The conversionID is SHA256 of the packed ConversionData
	// This matches the packing in ValidatorMessages.sol

	// Pack: codecID (2) + subnetID (32) + managerChainID (32) +
	//       managerAddressLen (4) + managerAddress (20) +
	//       validatorCount (4) + validators...

	packed := make([]byte, 0, 94+60*len(data.InitialValidators))

	// Codec ID (0)
	packed = append(packed, 0, 0)

	// SubnetID
	packed = append(packed, data.SubnetID[:]...)

	// ValidatorManagerBlockchainID
	packed = append(packed, data.ValidatorManagerBlockchainID[:]...)

	// Manager address length (20 for EVM)
	packed = append(packed, 0, 0, 0, 20)

	// Manager address (decode from hex string)
	addrHex := strings.TrimPrefix(data.ValidatorManagerAddress, "0x")
	addrBytes, err := hex.DecodeString(addrHex)
	if err != nil {
		return ids.Empty, fmt.Errorf("invalid manager address: %w", err)
	}
	packed = append(packed, addrBytes...)

	// Validator count
	count := uint32(len(data.InitialValidators))
	packed = append(packed, byte(count>>24), byte(count>>16), byte(count>>8), byte(count))

	// Each validator: nodeIDLen (4) + nodeID + blsKey (48) + weight (8)
	for _, v := range data.InitialValidators {
		// NodeID length
		nodeIDLen := uint32(len(v.NodeID))
		packed = append(packed, byte(nodeIDLen>>24), byte(nodeIDLen>>16), byte(nodeIDLen>>8), byte(nodeIDLen))

		// NodeID
		packed = append(packed, v.NodeID...)

		// BLS public key (48 bytes)
		if len(v.BlsPublicKey) != bls.PublicKeyLen {
			return ids.Empty, fmt.Errorf("invalid BLS public key length: %d", len(v.BlsPublicKey))
		}
		packed = append(packed, v.BlsPublicKey...)

		// Weight (big-endian uint64)
		packed = append(packed,
			byte(v.Weight>>56), byte(v.Weight>>48), byte(v.Weight>>40), byte(v.Weight>>32),
			byte(v.Weight>>24), byte(v.Weight>>16), byte(v.Weight>>8), byte(v.Weight))
	}

	return ids.ToID(packed)
}
