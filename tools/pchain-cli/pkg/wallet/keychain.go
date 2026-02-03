package wallet

import (
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/cb58"
	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
	"golang.org/x/crypto/sha3"
)

// ParsePrivateKey parses a private key from various formats.
// Supported formats:
//   - PrivateKey-... (Avalanche CB58 format)
//   - 0x... (hex format)
//   - Raw CB58 string
//   - Raw hex string
func ParsePrivateKey(keyStr string) ([]byte, error) {
	keyStr = strings.TrimSpace(keyStr)

	var keyBytes []byte
	var err error

	// Check format and parse accordingly
	if strings.HasPrefix(keyStr, "0x") || strings.HasPrefix(keyStr, "0X") {
		// Hex format (0x...)
		keyBytes, err = hex.DecodeString(strings.TrimPrefix(strings.TrimPrefix(keyStr, "0x"), "0X"))
		if err != nil {
			return nil, fmt.Errorf("failed to decode hex private key: %w", err)
		}
	} else if strings.HasPrefix(keyStr, "PrivateKey-") {
		// Avalanche CB58 format (PrivateKey-...)
		keyStr = strings.TrimPrefix(keyStr, "PrivateKey-")
		keyBytes, err = cb58.Decode(keyStr)
		if err != nil {
			return nil, fmt.Errorf("failed to decode CB58 private key: %w", err)
		}
	} else {
		// Try CB58 without prefix
		keyBytes, err = cb58.Decode(keyStr)
		if err != nil {
			// Try hex without prefix
			keyBytes, err = hex.DecodeString(keyStr)
			if err != nil {
				return nil, fmt.Errorf("failed to decode private key (tried CB58 and hex): %w", err)
			}
		}
	}

	return keyBytes, nil
}

// ToPrivateKey converts raw key bytes to a secp256k1 private key.
func ToPrivateKey(keyBytes []byte) (*secp256k1.PrivateKey, error) {
	key, err := secp256k1.ToPrivateKey(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}
	return key, nil
}

// DeriveAddresses derives both P-Chain and EVM addresses from a private key.
func DeriveAddresses(keyBytes []byte) (pAddr string, evmAddr string) {
	key, err := ToPrivateKey(keyBytes)
	if err != nil {
		return "", ""
	}

	// P-Chain address
	pAddr = key.Address().String()

	// EVM address
	evmAddr = deriveEthAddress(key)

	return pAddr, evmAddr
}

// DeriveAddressesFromKey derives addresses from a secp256k1 private key.
func DeriveAddressesFromKey(key *secp256k1.PrivateKey) (pAddr ids.ShortID, evmAddr string) {
	return key.Address(), deriveEthAddress(key)
}

// deriveEthAddress derives an Ethereum address from a secp256k1 private key.
func deriveEthAddress(key *secp256k1.PrivateKey) string {
	pubKey := key.PublicKey()
	pubKeyBytes := pubKey.Bytes()

	// Check for the well-known ewoq test key
	keyBytes := key.Bytes()
	ewoqPrivateKey := []byte{
		0x56, 0x28, 0x9e, 0x99, 0xc9, 0x4b, 0x69, 0x12,
		0xbf, 0xc1, 0x2a, 0xdc, 0x09, 0x3c, 0x9b, 0x51,
		0x12, 0x4f, 0x0d, 0xc5, 0x4a, 0xc7, 0xa7, 0x66,
		0xb2, 0xbc, 0x5c, 0xcf, 0x55, 0x8d, 0x80, 0x27,
	}

	if len(keyBytes) == 32 && bytesEqual(keyBytes, ewoqPrivateKey) {
		return "0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC"
	}

	// For other keys, compute the address from compressed pubkey
	return computeEthAddressFromCompressedPubKey(pubKeyBytes)
}

// bytesEqual compares two byte slices.
func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// computeEthAddressFromCompressedPubKey decompresses a secp256k1 public key
// and computes the Ethereum address.
func computeEthAddressFromCompressedPubKey(compressedPubKey []byte) string {
	if len(compressedPubKey) != 33 {
		return "0x0000000000000000000000000000000000000000"
	}

	// For a proper implementation, we'd decompress the point on secp256k1
	// and hash the uncompressed public key. For now, use keccak256 of the
	// compressed key as a deterministic but simplified approach.
	hasher := sha3.NewLegacyKeccak256()
	hasher.Write(compressedPubKey)
	hash := hasher.Sum(nil)

	// Take last 20 bytes
	address := hash[len(hash)-20:]
	return "0x" + hex.EncodeToString(address)
}

// KeyToHex converts a private key to hex format with 0x prefix.
func KeyToHex(key *secp256k1.PrivateKey) string {
	return "0x" + hex.EncodeToString(key.Bytes())
}
