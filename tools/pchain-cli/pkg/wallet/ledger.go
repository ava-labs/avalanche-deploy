//go:build ledger

package wallet

import (
	"fmt"
	"time"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
	"github.com/ava-labs/avalanchego/utils/set"
	ledger "github.com/ava-labs/ledger-avalanche-go"
)

const (
	// BIP44 root path for Avalanche: m/44'/9000'/0'
	ledgerRootPath = "m/44'/9000'/0'"

	// Maximum retries for Ledger operations
	ledgerMaxRetries = 5

	// Initial retry delay
	ledgerRetryDelay = 200 * time.Millisecond
)

// LedgerEnabled indicates whether Ledger support is compiled in.
const LedgerEnabled = true

// LedgerKeychain wraps a Ledger device to implement keychain functionality.
type LedgerKeychain struct {
	device    *ledger.LedgerAvalanche
	index     uint32
	address   ids.ShortID
	pubKey    *secp256k1.PublicKey
	addresses set.Set[ids.ShortID]
}

// NewLedgerKeychain creates a new keychain backed by a Ledger device.
func NewLedgerKeychain(addressIndex uint32) (*LedgerKeychain, error) {
	fmt.Println("  Connecting to Ledger device...")

	device, err := findLedgerWithRetry()
	if err != nil {
		return nil, fmt.Errorf("failed to find Ledger Avalanche app: %w\n\nMake sure:\n  1. Ledger is connected and unlocked\n  2. Avalanche app is open on the device\n  3. Ledger Live is NOT running", err)
	}

	fmt.Println("  Ledger connected successfully")

	// Derive the address at the specified index
	path := fmt.Sprintf("%s/0/%d", ledgerRootPath, addressIndex)
	fmt.Printf("  Deriving address at path: %s\n", path)

	addrResp, err := getPublicKeyWithRetry(device, path)
	if err != nil {
		device.Close()
		return nil, fmt.Errorf("failed to get public key from Ledger: %w", err)
	}

	pubKey, err := secp256k1.ToPublicKey(addrResp.PublicKey)
	if err != nil {
		device.Close()
		return nil, fmt.Errorf("failed to parse public key: %w", err)
	}

	address := pubKey.Address()
	fmt.Printf("  Ledger address: %s\n", address)

	addresses := set.NewSet[ids.ShortID](1)
	addresses.Add(address)

	kc := &LedgerKeychain{
		device:    device,
		index:     addressIndex,
		address:   address,
		pubKey:    pubKey,
		addresses: addresses,
	}

	return kc, nil
}

// Close closes the Ledger device connection.
func (kc *LedgerKeychain) Close() {
	if kc.device != nil {
		kc.device.Close()
	}
}

// Addresses returns the set of addresses managed by this keychain.
func (kc *LedgerKeychain) Addresses() set.Set[ids.ShortID] {
	return kc.addresses
}

// Get returns nil since Ledger never exposes private keys.
func (kc *LedgerKeychain) Get(addr ids.ShortID) (*secp256k1.PrivateKey, bool) {
	return nil, false
}

// GetAddress returns the primary address of the keychain.
func (kc *LedgerKeychain) GetAddress() ids.ShortID {
	return kc.address
}

// GetPublicKey returns the public key.
func (kc *LedgerKeychain) GetPublicKey() *secp256k1.PublicKey {
	return kc.pubKey
}

// SignHash signs a hash using the Ledger device.
func (kc *LedgerKeychain) SignHash(hash []byte) ([]byte, error) {
	path := fmt.Sprintf("%s/0/%d", ledgerRootPath, kc.index)

	fmt.Printf("\n  >>> Please confirm the transaction on your Ledger device <<<\n\n")

	sig, err := signHashWithRetry(kc.device, path, hash)
	if err != nil {
		return nil, fmt.Errorf("Ledger signing failed: %w", err)
	}

	return sig, nil
}

func findLedgerWithRetry() (*ledger.LedgerAvalanche, error) {
	var device *ledger.LedgerAvalanche
	var err error

	delay := ledgerRetryDelay
	for i := 0; i < ledgerMaxRetries; i++ {
		device, err = ledger.FindLedgerAvalancheApp()
		if err == nil {
			return device, nil
		}

		if i < ledgerMaxRetries-1 {
			time.Sleep(delay)
			delay *= 2
		}
	}

	return nil, err
}

func getPublicKeyWithRetry(device *ledger.LedgerAvalanche, path string) (*ledger.ResponseAddr, error) {
	var resp *ledger.ResponseAddr
	var err error

	delay := ledgerRetryDelay
	for i := 0; i < ledgerMaxRetries; i++ {
		resp, err = device.GetPubKey(path, false, "avax", "P")
		if err == nil {
			return resp, nil
		}

		if i < ledgerMaxRetries-1 {
			time.Sleep(delay)
			delay *= 2
		}
	}

	return nil, err
}

func signHashWithRetry(device *ledger.LedgerAvalanche, path string, hash []byte) ([]byte, error) {
	var err error

	delay := ledgerRetryDelay
	for i := 0; i < ledgerMaxRetries; i++ {
		response, signErr := device.SignHash(path, []string{path}, hash)
		if signErr == nil && response != nil {
			if sig, ok := response.Signature[path]; ok {
				return sig, nil
			}
			for _, sig := range response.Signature {
				return sig, nil
			}
		}
		err = signErr

		if i < ledgerMaxRetries-1 {
			time.Sleep(delay)
			delay *= 2
		}
	}

	return nil, err
}
