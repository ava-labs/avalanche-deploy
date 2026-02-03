package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var (
	// Global flags
	networkName string
	privateKey  string
	useLedger   bool
)

// rootCmd represents the base command when called without any subcommands
var rootCmd = &cobra.Command{
	Use:   "pchain-cli",
	Short: "Avalanche P-Chain command-line utilities",
	Long: `pchain-cli provides utilities for working with the Avalanche P-Chain.

Commands include:
  wallet  - Wallet operations (balance, address)
  subnet  - Subnet management (create)
  chain   - Chain management (create)
  node    - Node information (info)

Example usage:
  # Check wallet balance
  pchain-cli wallet balance --private-key "PrivateKey-..."

  # Get node ID and BLS key
  pchain-cli node info --ip 127.0.0.1

  # Create a subnet
  pchain-cli subnet create --network fuji --private-key "PrivateKey-..."`,
}

// Execute adds all child commands to the root command and sets flags appropriately.
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func init() {
	rootCmd.PersistentFlags().StringVarP(&networkName, "network", "n", "fuji", "Network: fuji or mainnet")
	rootCmd.PersistentFlags().StringVarP(&privateKey, "private-key", "k", "", "Private key (PrivateKey-... or 0x... format)")
	rootCmd.PersistentFlags().BoolVar(&useLedger, "ledger", false, "Use Ledger hardware wallet")
}
