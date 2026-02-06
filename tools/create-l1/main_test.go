package main

import (
	"encoding/hex"
	"testing"

	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
)

func TestDeriveEthAddressEwoq(t *testing.T) {
	t.Helper()

	// Known key used in many Avalanche test flows.
	keyBytes, err := hex.DecodeString("56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027")
	if err != nil {
		t.Fatalf("failed to decode key: %v", err)
	}
	key, err := secp256k1.ToPrivateKey(keyBytes)
	if err != nil {
		t.Fatalf("failed to parse key: %v", err)
	}

	got := deriveEthAddress(key)
	want := "0x8db97c7cece249c2b98bdc0226cc4c2a57bf52fc"
	if got != want {
		t.Fatalf("unexpected ETH address: got %s want %s", got, want)
	}
}

func TestExtractEVMChainID(t *testing.T) {
	t.Helper()

	tests := []struct {
		name    string
		genesis string
		want    string
	}{
		{
			name:    "numeric chain id",
			genesis: `{"config":{"chainId":99999}}`,
			want:    "99999",
		},
		{
			name:    "string chain id",
			genesis: `{"config":{"chainId":"43114"}}`,
			want:    "43114",
		},
		{
			name:    "missing chain id",
			genesis: `{"config":{"foo":"bar"}}`,
			want:    "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := extractEVMChainID([]byte(tc.genesis))
			if got != tc.want {
				t.Fatalf("unexpected chain id: got %q want %q", got, tc.want)
			}
		})
	}
}

func TestCheckGenesisFunding(t *testing.T) {
	t.Helper()

	genesis := []byte(`{
	  "alloc": {
	    "0xabc1230000000000000000000000000000000000": { "balance": "0xde0b6b3a7640000" }
	  }
	}`)

	funded, balance := checkGenesisFunding(genesis, "0xAbC1230000000000000000000000000000000000")
	if !funded {
		t.Fatalf("expected address to be funded")
	}
	if balance != "0xde0b6b3a7640000" {
		t.Fatalf("unexpected balance: %s", balance)
	}
}
