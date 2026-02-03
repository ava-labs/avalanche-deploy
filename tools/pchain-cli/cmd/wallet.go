package cmd

import (
	"context"
	"fmt"
	"os"

	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/network"
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/wallet"
	"github.com/spf13/cobra"
)

var walletCmd = &cobra.Command{
	Use:   "wallet",
	Short: "Wallet operations",
	Long:  `Wallet operations including balance check and address display.`,
}

var balanceCmd = &cobra.Command{
	Use:   "balance",
	Short: "Show P-Chain balance",
	Long:  `Display the P-Chain balance for the specified wallet.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := context.Background()

		keyBytes, err := loadKey()
		if err != nil {
			return err
		}

		key, err := wallet.ToPrivateKey(keyBytes)
		if err != nil {
			return err
		}

		netConfig := network.GetConfig(networkName)
		w, err := wallet.NewWallet(ctx, key, netConfig)
		if err != nil {
			return fmt.Errorf("failed to create wallet: %w", err)
		}

		balance, err := w.GetPChainBalance(ctx)
		if err != nil {
			return fmt.Errorf("failed to get balance: %w", err)
		}

		fmt.Printf("P-Chain Address: %s\n", w.PChainAddress())
		fmt.Printf("Balance: %.9f AVAX\n", float64(balance)/1e9)
		return nil
	},
}

var addressCmd = &cobra.Command{
	Use:   "address",
	Short: "Show wallet addresses",
	Long:  `Display P-Chain and EVM addresses for the specified wallet.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		key, err := loadKey()
		if err != nil {
			return err
		}

		pAddr, evmAddr := wallet.DeriveAddresses(key)

		fmt.Printf("P-Chain Address: %s\n", pAddr)
		fmt.Printf("EVM Address:     %s\n", evmAddr)
		return nil
	},
}

func loadKey() ([]byte, error) {
	keyStr := privateKey
	if keyStr == "" {
		keyStr = os.Getenv("AVALANCHE_PRIVATE_KEY")
	}
	if keyStr == "" {
		return nil, fmt.Errorf("no private key provided. Use --private-key or set AVALANCHE_PRIVATE_KEY env var")
	}
	return wallet.ParsePrivateKey(keyStr)
}

func init() {
	rootCmd.AddCommand(walletCmd)
	walletCmd.AddCommand(balanceCmd)
	walletCmd.AddCommand(addressCmd)
}
