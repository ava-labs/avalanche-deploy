// Package network provides Avalanche network configuration utilities.
package network

// Config holds network-specific configuration.
type Config struct {
	Name      string
	NetworkID uint32
	RPCURL    string
}

// Fuji testnet configuration
var Fuji = Config{
	Name:      "fuji",
	NetworkID: 5,
	RPCURL:    "https://api.avax-test.network",
}

// Mainnet configuration
var Mainnet = Config{
	Name:      "mainnet",
	NetworkID: 1,
	RPCURL:    "https://api.avax.network",
}

// GetConfig returns the network configuration for the given network name.
func GetConfig(name string) Config {
	switch name {
	case "mainnet":
		return Mainnet
	case "fuji":
		return Fuji
	default:
		// Default to Fuji
		return Fuji
	}
}

// GetNetworkIDAndRPC is a convenience function that returns both networkID and RPC URL.
func GetNetworkIDAndRPC(name string) (uint32, string) {
	config := GetConfig(name)
	return config.NetworkID, config.RPCURL
}
