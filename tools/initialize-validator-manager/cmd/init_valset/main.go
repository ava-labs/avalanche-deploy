package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/api/info"
	"github.com/ava-labs/avalanchego/ids"
	avagoconstants "github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/message"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/payload"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

var (
	subnetIDStr      string
	chainIDStr       string
	managerAddr      string
	privateKey       string
	rpcURL           string
	sigAggURL        string
	validatorURLs    string
	networkID        uint
	validatorWeights string
)

func main() {
	flag.StringVar(&subnetIDStr, "subnet-id", "", "Subnet ID")
	flag.StringVar(&chainIDStr, "chain-id", "", "Chain ID")
	flag.StringVar(&managerAddr, "manager-address", "", "ValidatorManager proxy address")
	flag.StringVar(&privateKey, "private-key", "", "Private key (0x...)")
	flag.StringVar(&rpcURL, "rpc-url", "", "L1 RPC URL")
	flag.StringVar(&sigAggURL, "sig-agg-url", "http://localhost:8080", "Signature aggregator URL")
	flag.StringVar(&validatorURLs, "validator-urls", "", "Comma-separated validator node URLs")
	flag.UintVar(&networkID, "network-id", 5, "Network ID (5 for Fuji)")
	flag.StringVar(&validatorWeights, "validator-weights", "", "Comma-separated validator weights (default: 49463 each)")
	flag.Parse()

	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	// Parse IDs
	subnetID, err := ids.FromString(subnetIDStr)
	if err != nil {
		return fmt.Errorf("invalid subnet ID: %w", err)
	}

	chainID, err := ids.FromString(chainIDStr)
	if err != nil {
		return fmt.Errorf("invalid chain ID: %w", err)
	}

	managerAddress := common.HexToAddress(managerAddr)

	// Parse validator URLs
	urls := strings.Split(validatorURLs, ",")
	if len(urls) == 0 {
		return fmt.Errorf("no validator URLs provided")
	}

	// Parse weights
	weights := make([]uint64, len(urls))
	if validatorWeights != "" {
		weightStrs := strings.Split(validatorWeights, ",")
		for i, w := range weightStrs {
			var weight uint64
			fmt.Sscanf(w, "%d", &weight)
			weights[i] = weight
		}
	} else {
		for i := range weights {
			weights[i] = 49463 // Default weight
		}
	}

	fmt.Println("=== Initialize Validator Set ===")
	fmt.Printf("Subnet ID: %s\n", subnetID)
	fmt.Printf("Chain ID: %s\n", chainID)
	fmt.Printf("Manager Address: %s\n", managerAddress.Hex())
	fmt.Printf("Validators: %d\n", len(urls))

	// Step 1: Gather validator info
	fmt.Println("\n[1/4] Gathering validator info...")
	validators := make([]ValidatorData, len(urls))
	for i, url := range urls {
		nodeID, blsKey, err := getValidatorInfo(url)
		if err != nil {
			return fmt.Errorf("failed to get info from %s: %w", url, err)
		}
		validators[i] = ValidatorData{
			NodeID:       nodeID.Bytes(),
			BLSPublicKey: blsKey,
			Weight:       weights[i],
		}
		fmt.Printf("  Validator %d: %s (weight: %d)\n", i+1, nodeID, weights[i])
	}

	// Step 2: Build unsigned warp message
	fmt.Println("\n[2/4] Building warp message...")
	unsignedMsg, conversionID, err := buildWarpMessage(uint32(networkID), subnetID, chainID, managerAddress, validators)
	if err != nil {
		return fmt.Errorf("failed to build warp message: %w", err)
	}
	fmt.Printf("  Conversion ID: %s\n", hex.EncodeToString(conversionID[:]))
	fmt.Printf("  Unsigned message: %s...\n", hex.EncodeToString(unsignedMsg.Bytes())[:64])

	// Step 3: Get signature from aggregator
	fmt.Println("\n[3/4] Requesting signature from aggregator...")
	signedMsg, err := signWarpMessage(sigAggURL, unsignedMsg, subnetID)
	if err != nil {
		return fmt.Errorf("failed to sign warp message: %w", err)
	}
	fmt.Printf("  Signed message length: %d bytes\n", len(signedMsg))

	// Step 4: Send transaction
	fmt.Println("\n[4/4] Sending initializeValidatorSet transaction...")
	tx, err := sendInitTx(rpcURL, privateKey, managerAddress, subnetID, chainID, validators, signedMsg)
	if err != nil {
		return fmt.Errorf("failed to send transaction: %w", err)
	}
	fmt.Printf("  Transaction hash: %s\n", tx.Hash().Hex())

	// Wait for receipt
	fmt.Println("\nWaiting for transaction receipt...")
	receipt, err := waitForReceipt(rpcURL, tx.Hash())
	if err != nil {
		return fmt.Errorf("failed to get receipt: %w", err)
	}

	if receipt.Status == 1 {
		fmt.Println("\n✅ Validator set initialized successfully!")
	} else {
		fmt.Println("\n❌ Transaction failed!")
		return fmt.Errorf("transaction reverted")
	}

	return nil
}

type ValidatorData struct {
	NodeID       []byte
	BLSPublicKey []byte
	Weight       uint64
}

func getValidatorInfo(nodeURL string) (ids.NodeID, []byte, error) {
	infoClient := info.NewClient(nodeURL)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	nodeID, pop, err := infoClient.GetNodeID(ctx)
	if err != nil {
		return ids.EmptyNodeID, nil, err
	}

	return nodeID, pop.PublicKey[:], nil
}

func buildWarpMessage(networkID uint32, subnetID, chainID ids.ID, managerAddress common.Address, validators []ValidatorData) (*warp.UnsignedMessage, ids.ID, error) {
	// Build validator data for the message
	msgValidators := make([]message.SubnetToL1ConversionValidatorData, len(validators))
	for i, v := range validators {
		var blsKey [48]byte // BLS public key is 48 bytes
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
	conversionID, err := message.SubnetToL1ConversionID(subnetConversionData)
	if err != nil {
		return nil, ids.Empty, fmt.Errorf("failed to create subnet conversion ID: %w", err)
	}

	// Create addressed call payload
	addressedCallPayload, err := message.NewSubnetToL1Conversion(conversionID)
	if err != nil {
		return nil, ids.Empty, fmt.Errorf("failed to create addressed call payload: %w", err)
	}

	// Wrap in AddressedCall (nil source for P-Chain)
	subnetConversionAddressedCall, err := payload.NewAddressedCall(
		nil,
		addressedCallPayload.Bytes(),
	)
	if err != nil {
		return nil, ids.Empty, fmt.Errorf("failed to create addressed call: %w", err)
	}

	// Build unsigned warp message - source is P-Chain
	unsignedMessage, err := warp.NewUnsignedMessage(
		networkID,
		avagoconstants.PlatformChainID,
		subnetConversionAddressedCall.Bytes(),
	)
	if err != nil {
		return nil, ids.Empty, fmt.Errorf("failed to create unsigned message: %w", err)
	}

	return unsignedMessage, conversionID, nil
}

func signWarpMessage(sigAggURL string, unsignedMsg *warp.UnsignedMessage, subnetID ids.ID) ([]byte, error) {
	msgHex := hex.EncodeToString(unsignedMsg.Bytes())

	reqBody := map[string]interface{}{
		"message":            msgHex,
		"signing-subnet-id":  subnetID.String(),
		"quorum-percentage":  67,
	}

	jsonBody, _ := json.Marshal(reqBody)

	client := &http.Client{Timeout: 180 * time.Second}
	resp, err := client.Post(sigAggURL+"/aggregate-signatures", "application/json", bytes.NewReader(jsonBody))
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("aggregator returned %d: %s", resp.StatusCode, string(body))
	}

	var result struct {
		SignedMessage string `json:"signed-message"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return hex.DecodeString(strings.TrimPrefix(result.SignedMessage, "0x"))
}

func sendInitTx(rpcURL, privateKeyHex string, managerAddress common.Address, subnetID, chainID ids.ID, validators []ValidatorData, signedWarpMessage []byte) (*types.Transaction, error) {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect: %w", err)
	}
	defer client.Close()

	privateKey, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("invalid private key: %w", err)
	}
	fromAddress := crypto.PubkeyToAddress(privateKey.PublicKey)

	// Build ABI
	abiJSON := `[{"inputs":[{"components":[{"internalType":"bytes32","name":"subnetID","type":"bytes32"},{"internalType":"bytes32","name":"validatorManagerBlockchainID","type":"bytes32"},{"internalType":"address","name":"validatorManagerAddress","type":"address"},{"components":[{"internalType":"bytes","name":"nodeID","type":"bytes"},{"internalType":"bytes","name":"blsPublicKey","type":"bytes"},{"internalType":"uint64","name":"weight","type":"uint64"}],"internalType":"struct InitialValidator[]","name":"initialValidators","type":"tuple[]"}],"internalType":"struct ConversionData","name":"conversionData","type":"tuple"},{"internalType":"uint32","name":"messageIndex","type":"uint32"}],"name":"initializeValidatorSet","outputs":[],"stateMutability":"nonpayable","type":"function"}]`

	parsedABI, err := abi.JSON(strings.NewReader(abiJSON))
	if err != nil {
		return nil, fmt.Errorf("failed to parse ABI: %w", err)
	}

	// Build conversion data struct for ABI encoding
	type InitialValidator struct {
		NodeID       []byte
		BlsPublicKey []byte
		Weight       uint64
	}
	type ConversionData struct {
		SubnetID                     [32]byte
		ValidatorManagerBlockchainID [32]byte
		ValidatorManagerAddress      common.Address
		InitialValidators            []InitialValidator
	}

	initialValidators := make([]InitialValidator, len(validators))
	for i, v := range validators {
		initialValidators[i] = InitialValidator{
			NodeID:       v.NodeID,
			BlsPublicKey: v.BLSPublicKey,
			Weight:       v.Weight,
		}
	}

	conversionData := ConversionData{
		SubnetID:                     subnetID,
		ValidatorManagerBlockchainID: chainID,
		ValidatorManagerAddress:      managerAddress,
		InitialValidators:            initialValidators,
	}

	callData, err := parsedABI.Pack("initializeValidatorSet", conversionData, uint32(0))
	if err != nil {
		return nil, fmt.Errorf("failed to pack call data: %w", err)
	}

	ctx := context.Background()
	nonce, err := client.PendingNonceAt(ctx, fromAddress)
	if err != nil {
		return nil, fmt.Errorf("failed to get nonce: %w", err)
	}

	gasPrice, err := client.SuggestGasPrice(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get gas price: %w", err)
	}

	evmChainID, err := client.ChainID(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get chain ID: %w", err)
	}

	// Build access list with warp precompile and signed message
	warpPrecompile := common.HexToAddress("0x0200000000000000000000000000000000000005")

	// The signed warp message becomes a storage key in the access list
	// This is how we pass the warp message to the precompile
	storageKeys := []common.Hash{
		common.BytesToHash(signedWarpMessage),
	}

	accessList := types.AccessList{
		{
			Address:     warpPrecompile,
			StorageKeys: storageKeys,
		},
	}

	// Create access list transaction
	tx := types.NewTx(&types.AccessListTx{
		ChainID:    evmChainID,
		Nonce:      nonce,
		GasPrice:   gasPrice,
		Gas:        1000000,
		To:         &managerAddress,
		Value:      big.NewInt(0),
		Data:       callData,
		AccessList: accessList,
	})

	signer := types.NewEIP2930Signer(evmChainID)
	signedTx, err := types.SignTx(tx, signer, privateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to sign tx: %w", err)
	}

	if err := client.SendTransaction(ctx, signedTx); err != nil {
		return nil, fmt.Errorf("failed to send tx: %w", err)
	}

	return signedTx, nil
}

func waitForReceipt(rpcURL string, txHash common.Hash) (*types.Receipt, error) {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, err
	}
	defer client.Close()

	ctx := context.Background()
	for i := 0; i < 60; i++ {
		receipt, err := client.TransactionReceipt(ctx, txHash)
		if err == nil {
			return receipt, nil
		}
		time.Sleep(2 * time.Second)
	}
	return nil, fmt.Errorf("timeout waiting for receipt")
}
