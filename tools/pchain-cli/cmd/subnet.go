package cmd

import (
	"context"
	"fmt"

	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/network"
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/pchain"
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/pkg/wallet"
	"github.com/spf13/cobra"
)

var subnetCmd = &cobra.Command{
	Use:   "subnet",
	Short: "Subnet management",
	Long:  `Subnet management operations including create and convert.`,
}

var subnetCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a new subnet",
	Long:  `Issue a CreateSubnetTx to create a new subnet on the P-Chain.`,
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

		subnetID, err := pchain.CreateSubnet(ctx, w)
		if err != nil {
			return fmt.Errorf("failed to create subnet: %w", err)
		}

		fmt.Printf("Subnet ID: %s\n", subnetID)
		return nil
	},
}

var (
	convertSubnetID  string
	convertChainID   string
	convertManager   string
	convertValidators string
	convertBalance   float64
)

var subnetConvertCmd = &cobra.Command{
	Use:   "convert",
	Short: "Convert subnet to L1",
	Long:  `Issue a ConvertSubnetToL1Tx to convert a subnet to an L1 blockchain.`,
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

		if convertSubnetID == "" {
			return fmt.Errorf("--subnet-id is required")
		}
		if convertChainID == "" {
			return fmt.Errorf("--chain-id is required")
		}

		txID, err := pchain.ConvertSubnetToL1(ctx, w, pchain.ConvertConfig{
			SubnetID:         convertSubnetID,
			ChainID:          convertChainID,
			ManagerAddress:   convertManager,
			ValidatorIPs:     convertValidators,
			ValidatorBalance: convertBalance,
		})
		if err != nil {
			return fmt.Errorf("failed to convert subnet: %w", err)
		}

		fmt.Printf("Conversion TX ID: %s\n", txID)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(subnetCmd)
	subnetCmd.AddCommand(subnetCreateCmd)
	subnetCmd.AddCommand(subnetConvertCmd)

	subnetConvertCmd.Flags().StringVar(&convertSubnetID, "subnet-id", "", "Subnet ID to convert")
	subnetConvertCmd.Flags().StringVar(&convertChainID, "chain-id", "", "Chain ID of the L1")
	subnetConvertCmd.Flags().StringVar(&convertManager, "manager", "", "Validator manager address (optional)")
	subnetConvertCmd.Flags().StringVar(&convertValidators, "validators", "", "Comma-separated validator IPs")
	subnetConvertCmd.Flags().Float64Var(&convertBalance, "balance", 1.0, "Validator balance in AVAX")
}
