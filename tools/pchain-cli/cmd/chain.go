package cmd

import (
	"context"
	"fmt"
	"os"

	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/network"
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/pchain"
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/wallet"
	"github.com/spf13/cobra"
)

var chainCmd = &cobra.Command{
	Use:   "chain",
	Short: "Chain management",
	Long:  `Chain management operations including create.`,
}

var (
	chainSubnetID   string
	chainGenesisFile string
	chainName       string
)

var chainCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a new chain",
	Long:  `Issue a CreateChainTx to create a new chain on a subnet.`,
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

		if chainSubnetID == "" {
			return fmt.Errorf("--subnet-id is required")
		}

		genesis, err := os.ReadFile(chainGenesisFile)
		if err != nil {
			return fmt.Errorf("failed to read genesis file: %w", err)
		}

		chainID, err := pchain.CreateChain(ctx, w, pchain.ChainConfig{
			SubnetID:     chainSubnetID,
			GenesisBytes: genesis,
			ChainName:    chainName,
		})
		if err != nil {
			return fmt.Errorf("failed to create chain: %w", err)
		}

		fmt.Printf("Chain ID: %s\n", chainID)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(chainCmd)
	chainCmd.AddCommand(chainCreateCmd)

	chainCreateCmd.Flags().StringVar(&chainSubnetID, "subnet-id", "", "Subnet ID to create chain on")
	chainCreateCmd.Flags().StringVar(&chainGenesisFile, "genesis", "genesis.json", "Genesis file path")
	chainCreateCmd.Flags().StringVar(&chainName, "name", "mychain", "Chain name (alphanumeric only)")
}
