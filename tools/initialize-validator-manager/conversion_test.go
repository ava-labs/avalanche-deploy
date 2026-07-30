package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/vms/platformvm/signer"
	"github.com/ava-labs/avalanchego/vms/platformvm/txs"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp"
	warpmessage "github.com/ava-labs/avalanchego/vms/platformvm/warp/message"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp/payload"
	"github.com/ava-labs/avalanchego/vms/types"
)

const testManagerAddress = "0x1111111111111111111111111111111111111111"

func TestExtractAuthoritativeConversionUsesExactTransactionValidators(t *testing.T) {
	subnetID := ids.GenerateTestID()
	chainID := ids.GenerateTestID()
	nodeID := ids.GenerateTestNodeID()
	const conversionWeight uint64 = 49_463_000

	var proof signer.ProofOfPossession
	for i := range proof.PublicKey {
		proof.PublicKey[i] = byte(i + 1)
	}
	tx := conversionFixture(subnetID, chainID, nodeID, proof, conversionWeight, testManagerAddress)

	conversion, err := extractAuthoritativeConversion(tx, subnetID, chainID, testManagerAddress)
	if err != nil {
		t.Fatalf("extractAuthoritativeConversion returned error: %v", err)
	}
	if len(conversion.Validators) != 1 {
		t.Fatalf("got %d validators, want exactly the one validator committed by the conversion", len(conversion.Validators))
	}

	gotValidator := conversion.Validators[0]
	if gotValidator.NodeID != nodeID {
		t.Fatalf("node ID mismatch: got %s want %s", gotValidator.NodeID, nodeID)
	}
	if gotValidator.Weight != conversionWeight {
		t.Fatalf("weight mismatch: got %d want %d", gotValidator.Weight, conversionWeight)
	}
	if !bytes.Equal(gotValidator.PublicKey, proof.PublicKey[:]) {
		t.Fatal("BLS public key did not match the accepted conversion transaction")
	}

	conversionID, err := conversion.conversionID()
	if err != nil {
		t.Fatalf("conversionID returned error: %v", err)
	}
	if conversionID == ids.Empty {
		t.Fatal("conversion ID must not be empty")
	}
}

func TestExtractAuthoritativeConversionRejectsMetadataMismatch(t *testing.T) {
	subnetID := ids.GenerateTestID()
	chainID := ids.GenerateTestID()
	nodeID := ids.GenerateTestNodeID()
	tx := conversionFixture(
		subnetID,
		chainID,
		nodeID,
		signer.ProofOfPossession{},
		1000,
		testManagerAddress,
	)

	tests := []struct {
		name            string
		expectedSubnet  ids.ID
		expectedChain   ids.ID
		expectedAddress string
		wantError       string
	}{
		{
			name:            "subnet",
			expectedSubnet:  ids.GenerateTestID(),
			expectedChain:   chainID,
			expectedAddress: testManagerAddress,
			wantError:       "conversion subnet mismatch",
		},
		{
			name:            "blockchain",
			expectedSubnet:  subnetID,
			expectedChain:   ids.GenerateTestID(),
			expectedAddress: testManagerAddress,
			wantError:       "conversion blockchain mismatch",
		},
		{
			name:            "manager address",
			expectedSubnet:  subnetID,
			expectedChain:   chainID,
			expectedAddress: "0x2222222222222222222222222222222222222222",
			wantError:       "conversion manager address mismatch",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := extractAuthoritativeConversion(
				tx,
				test.expectedSubnet,
				test.expectedChain,
				test.expectedAddress,
			)
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("got error %v, want one containing %q", err, test.wantError)
			}
		})
	}
}

func TestDeriveAvalancheNodeURL(t *testing.T) {
	got, err := deriveAvalancheNodeURL("http://10.0.0.12:9650/ext/bc/abc/rpc")
	if err != nil {
		t.Fatalf("deriveAvalancheNodeURL returned error: %v", err)
	}
	if got != "http://10.0.0.12:9650" {
		t.Fatalf("got %q, want node origin", got)
	}
}

func TestValidateSignedConversionMessage(t *testing.T) {
	conversionID := ids.GenerateTestID()
	conversionPayload, err := warpmessage.NewSubnetToL1Conversion(conversionID)
	if err != nil {
		t.Fatalf("NewSubnetToL1Conversion returned error: %v", err)
	}
	addressedCall, err := payload.NewAddressedCall(nil, conversionPayload.Bytes())
	if err != nil {
		t.Fatalf("NewAddressedCall returned error: %v", err)
	}
	unsignedMessage, err := warp.NewUnsignedMessage(
		constants.FujiID,
		constants.PlatformChainID,
		addressedCall.Bytes(),
	)
	if err != nil {
		t.Fatalf("NewUnsignedMessage returned error: %v", err)
	}
	signedMessage, err := warp.NewMessage(unsignedMessage, &warp.BitSetSignature{})
	if err != nil {
		t.Fatalf("NewMessage returned error: %v", err)
	}

	if err := validateSignedConversionMessage(signedMessage.Bytes(), constants.FujiID, conversionID); err != nil {
		t.Fatalf("validateSignedConversionMessage returned error: %v", err)
	}
	if err := validateSignedConversionMessage(signedMessage.Bytes(), constants.FujiID, ids.GenerateTestID()); err == nil {
		t.Fatal("expected conversion ID mismatch")
	}
}

func conversionFixture(
	subnetID ids.ID,
	chainID ids.ID,
	nodeID ids.NodeID,
	proof signer.ProofOfPossession,
	weight uint64,
	managerAddress string,
) *txs.Tx {
	address, err := decodeEVMAddress(managerAddress)
	if err != nil {
		panic(err)
	}
	return &txs.Tx{
		Unsigned: &txs.ConvertSubnetToL1Tx{
			Subnet:  subnetID,
			ChainID: chainID,
			Address: types.JSONByteSlice(address),
			Validators: []*txs.ConvertSubnetToL1Validator{
				{
					NodeID: types.JSONByteSlice(nodeID[:]),
					Weight: weight,
					Signer: proof,
				},
			},
		},
	}
}
