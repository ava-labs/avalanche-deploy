package main

import (
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/constants"
	"github.com/ava-labs/avalanchego/vms/platformvm/warp"
)

func TestBuildAndSignConversionMessageFromIDUsesL1SigningSubnet(t *testing.T) {
	subnetID := ids.GenerateTestID()
	conversionID := ids.GenerateTestID()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/aggregate-signatures" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		var request struct {
			Message          string `json:"message"`
			Justification    string `json:"justification"`
			SigningSubnetID  string `json:"signing-subnet-id"`
			QuorumPercentage int    `json:"quorum-percentage"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Errorf("decode request: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}

		expectedSubnetHex := "0x" + hex.EncodeToString(subnetID[:])
		if request.SigningSubnetID != expectedSubnetHex {
			t.Errorf("signing subnet ID = %q, want %q", request.SigningSubnetID, expectedSubnetHex)
		}
		if request.Justification != expectedSubnetHex {
			t.Errorf("justification = %q, want %q", request.Justification, expectedSubnetHex)
		}
		if request.QuorumPercentage != 67 {
			t.Errorf("quorum percentage = %d, want 67", request.QuorumPercentage)
		}

		unsignedBytes, err := hex.DecodeString(request.Message)
		if err != nil {
			t.Errorf("decode unsigned message: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		unsignedMessage, err := warp.ParseUnsignedMessage(unsignedBytes)
		if err != nil {
			t.Errorf("parse unsigned message: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		signedMessage, err := warp.NewMessage(unsignedMessage, &warp.BitSetSignature{})
		if err != nil {
			t.Errorf("build signed message: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]string{
			"signed-message": hex.EncodeToString(signedMessage.Bytes()),
		}); err != nil {
			t.Errorf("encode response: %v", err)
		}
	}))
	defer server.Close()

	signedMessage, err := BuildAndSignConversionMessageFromID(
		server.URL,
		constants.FujiID,
		subnetID,
		conversionID,
	)
	if err != nil {
		t.Fatalf("BuildAndSignConversionMessageFromID returned error: %v", err)
	}
	if err := validateSignedConversionMessage(signedMessage, constants.FujiID, conversionID); err != nil {
		t.Fatalf("validateSignedConversionMessage returned error: %v", err)
	}
}
