// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// avalanche-kms-signer is an open-source BLS signing sidecar for AvalancheGo.
//
// Subcommands:
//
//	serve       Start the gRPC signing server (default behaviour)
//	keytool generate   Create a new BLS key and encrypt it with KMS
//	keytool migrate    Encrypt an existing plaintext signer.key with KMS
//
// AvalancheGo must be started with:
//
//	--staking-rpc-signer-endpoint=127.0.0.1:50051
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/ava-labs/avalanche-kms-signer/backend"
	"github.com/ava-labs/avalanche-kms-signer/backend/awskms"
	"github.com/ava-labs/avalanche-kms-signer/backend/azurekv"
	"github.com/ava-labs/avalanche-kms-signer/backend/gcpkms"
	"github.com/ava-labs/avalanche-kms-signer/backend/memory"
	vaultbackend "github.com/ava-labs/avalanche-kms-signer/backend/vault"
	"github.com/ava-labs/avalanche-kms-signer/config"
	"github.com/ava-labs/avalanche-kms-signer/keytool"
	"github.com/ava-labs/avalanche-kms-signer/signerserver"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	if err := rootCmd(log).Execute(); err != nil {
		os.Exit(1)
	}
}

// rootCmd builds the top-level cobra command.
func rootCmd(log *slog.Logger) *cobra.Command {
	root := &cobra.Command{
		Use:   "avalanche-kms-signer",
		Short: "BLS signing sidecar for AvalancheGo backed by cloud KMS",
	}
	root.AddCommand(serveCmd(log))
	root.AddCommand(keytoolCmd())
	return root
}

// ── serve ─────────────────────────────────────────────────────────────────────

func serveCmd(log *slog.Logger) *cobra.Command {
	var (
		configFile  string
		backendFlag string
		port        int
		listen      string
		awsEndpoint string
	)

	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Start the gRPC BLS signing server",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load(configFile)
			if err != nil {
				return fmt.Errorf("loading config: %w", err)
			}
			if backendFlag != "" {
				cfg.Backend = config.BackendType(backendFlag)
			}
			if port != 0 {
				cfg.Port = port
			}
			if listen != "" {
				cfg.Listen = listen
			}
			if awsEndpoint != "" {
				cfg.AWS.EndpointURL = awsEndpoint
			}

			log.Info("starting avalanche-kms-signer",
				"backend", cfg.Backend,
				"addr", cfg.Addr(),
			)

			b, err := buildBackend(cfg, log)
			if err != nil {
				return fmt.Errorf("building backend %q: %w", cfg.Backend, err)
			}
			defer func() {
				if err := b.Close(); err != nil {
					log.Error("backend Close failed", "err", err)
				}
			}()

			ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
			defer cancel()

			srv := signerserver.New(b, log)
			return signerserver.ListenAndServe(ctx, cfg.Addr(), srv)
		},
	}

	cmd.Flags().StringVar(&configFile, "config-file", "", "path to YAML config file")
	cmd.Flags().StringVar(&backendFlag, "backend", "", "signing backend: memory|aws-kms|gcp-kms|azure-kv")
	cmd.Flags().IntVar(&port, "port", 0, "gRPC listen port (overrides config file)")
	cmd.Flags().StringVar(&listen, "listen", "", "gRPC listen address (overrides config file)")
	cmd.Flags().StringVar(&awsEndpoint, "aws-endpoint-url", "", "override AWS KMS endpoint (e.g. http://localhost:4566 for LocalStack)")

	return cmd
}

// ── keytool ───────────────────────────────────────────────────────────────────

func keytoolCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "keytool",
		Short: "Manage BLS keys for use with cloud KMS backends",
	}
	cmd.AddCommand(keytoolGenerateCmd())
	cmd.AddCommand(keytoolMigrateCmd())
	return cmd
}

// commonKMSFlags attaches the KMS config flags shared by generate and migrate.
// It returns a config.Config pointer that will be populated after cobra parses flags.
func commonKMSFlags(cmd *cobra.Command) *config.Config {
	cfg := &config.Config{}

	// Config file (optional — CLI flags override it).
	cmd.Flags().String("config-file", "", "path to YAML config file (KMS settings can come from here)")

	// Backend selector.
	cmd.Flags().String("backend", "", "KMS backend: aws-kms|gcp-kms|azure-kv|vault (required)")
	_ = cmd.MarkFlagRequired("backend")

	// AWS flags.
	cmd.Flags().String("aws-region", "", "AWS region (e.g. us-east-1)")
	cmd.Flags().String("aws-kms-key-id", "", "AWS KMS key ID or ARN")
	cmd.Flags().String("aws-endpoint-url", "", "override AWS KMS endpoint (e.g. http://localhost:4566 for LocalStack)")

	// GCP flags.
	cmd.Flags().String("gcp-project", "", "GCP project ID")
	cmd.Flags().String("gcp-location", "", "GCP location (e.g. us-central1)")
	cmd.Flags().String("gcp-key-ring", "", "GCP KMS key ring name")
	cmd.Flags().String("gcp-key-name", "", "GCP KMS key name")

	// Azure flags.
	cmd.Flags().String("azure-vault-url", "", "Azure Key Vault URL (e.g. https://my-vault.vault.azure.net/)")
	cmd.Flags().String("azure-key-name", "", "Azure Key Vault key name")

	// Vault flags.
	cmd.Flags().String("vault-addr", "", "Vault server address (e.g. http://127.0.0.1:8200)")
	cmd.Flags().String("vault-token", "", "Vault token for authentication")
	cmd.Flags().String("vault-mount-path", "bls", "Vault secrets engine mount path")
	cmd.Flags().String("vault-key-name", "", "Name of the BLS key within Vault")

	return cfg
}

// resolveKMSConfig merges the optional config file with CLI flag overrides.
func resolveKMSConfig(cmd *cobra.Command) (config.Config, error) {
	configFile, _ := cmd.Flags().GetString("config-file")
	cfg, err := config.Load(configFile)
	if err != nil {
		return cfg, fmt.Errorf("loading config file: %w", err)
	}

	if v, _ := cmd.Flags().GetString("backend"); v != "" {
		cfg.Backend = config.BackendType(v)
	}

	// AWS overrides.
	if v, _ := cmd.Flags().GetString("aws-region"); v != "" {
		cfg.AWS.Region = v
	}
	if v, _ := cmd.Flags().GetString("aws-kms-key-id"); v != "" {
		cfg.AWS.KMSKeyID = v
	}
	if v, _ := cmd.Flags().GetString("aws-endpoint-url"); v != "" {
		cfg.AWS.EndpointURL = v
	}

	// GCP overrides.
	if v, _ := cmd.Flags().GetString("gcp-project"); v != "" {
		cfg.GCP.Project = v
	}
	if v, _ := cmd.Flags().GetString("gcp-location"); v != "" {
		cfg.GCP.Location = v
	}
	if v, _ := cmd.Flags().GetString("gcp-key-ring"); v != "" {
		cfg.GCP.KeyRing = v
	}
	if v, _ := cmd.Flags().GetString("gcp-key-name"); v != "" {
		cfg.GCP.KeyName = v
	}

	// Azure overrides.
	if v, _ := cmd.Flags().GetString("azure-vault-url"); v != "" {
		cfg.Azure.VaultURL = v
	}
	if v, _ := cmd.Flags().GetString("azure-key-name"); v != "" {
		cfg.Azure.KeyName = v
	}

	// Vault overrides.
	if v, _ := cmd.Flags().GetString("vault-addr"); v != "" {
		cfg.Vault.Address = v
	}
	if v, _ := cmd.Flags().GetString("vault-token"); v != "" {
		cfg.Vault.Token = v
	}
	if v, _ := cmd.Flags().GetString("vault-mount-path"); v != "" {
		cfg.Vault.MountPath = v
	}
	if v, _ := cmd.Flags().GetString("vault-key-name"); v != "" {
		cfg.Vault.KeyName = v
	}

	return cfg, nil
}

func keytoolGenerateCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "generate",
		Short: "Generate a new BLS key and encrypt it with the chosen KMS backend",
		Example: `  # AWS KMS
  avalanche-kms-signer keytool generate \
    --backend aws-kms \
    --aws-region us-east-1 \
    --aws-kms-key-id arn:aws:kms:us-east-1:123456789:key/abc-def \
    --output /etc/avalanche/bls.key.enc

  # HashiCorp Vault (key stays inside Vault — no output file)
  avalanche-kms-signer keytool generate \
    --backend vault \
    --vault-addr http://127.0.0.1:8200 \
    --vault-token root \
    --vault-key-name validator`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := resolveKMSConfig(cmd)
			if err != nil {
				return err
			}

			isVault := cfg.Backend == config.BackendVault
			output, _ := cmd.Flags().GetString("output")

			if !isVault && output == "" {
				return fmt.Errorf("--output is required for backend %q", cfg.Backend)
			}

			// Propagate output path into the right config field.
			switch cfg.Backend {
			case config.BackendAWSKMS:
				cfg.AWS.EncryptedBLSKeyPath = output
			case config.BackendGCPKMS:
				cfg.GCP.EncryptedBLSKeyPath = output
			case config.BackendAzureKV:
				cfg.Azure.EncryptedBLSKeyPath = output
			}

			pkHex, err := keytool.Generate(keytool.GenerateOpts{
				Backend:    string(cfg.Backend),
				OutputPath: output,
				AWS:        cfg.AWS,
				GCP:        cfg.GCP,
				Azure:      cfg.Azure,
				Vault:      cfg.Vault,
			})
			if err != nil {
				return err
			}

			if isVault {
				fmt.Printf("BLS key generated inside Vault at: %s/keys/%s\n", cfg.Vault.MountPath, cfg.Vault.KeyName)
			} else {
				fmt.Printf("Encrypted key written to: %s\n", output)
			}
			fmt.Printf("BLS public key (hex):     %s\n", pkHex)
			fmt.Println()
			fmt.Println("IMPORTANT: verify this public key matches your on-chain registration before")
			fmt.Println("starting your validator node.  Check with: avalanche-cli node list")
			return nil
		},
	}

	commonKMSFlags(cmd)
	cmd.Flags().String("output", "", "path to write the encrypted key blob (not needed for vault backend)")

	return cmd
}

func keytoolMigrateCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "migrate",
		Short: "Encrypt an existing plaintext signer.key with the chosen KMS backend",
		Example: `  avalanche-kms-signer keytool migrate \
    --backend aws-kms \
    --aws-region us-east-1 \
    --aws-kms-key-id arn:aws:kms:us-east-1:123456789:key/abc-def \
    --input ~/.avalanchego/staking/signer.key \
    --output /etc/avalanche/bls.key.enc \
    --delete-input`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := resolveKMSConfig(cmd)
			if err != nil {
				return err
			}
			input, _ := cmd.Flags().GetString("input")
			output, _ := cmd.Flags().GetString("output")
			deleteInput, _ := cmd.Flags().GetBool("delete-input")

			isVault := cfg.Backend == config.BackendVault
			if !isVault && output == "" {
				return fmt.Errorf("--output is required for backend %q", cfg.Backend)
			}

			pkHex, err := keytool.Migrate(keytool.MigrateOpts{
				Backend:     string(cfg.Backend),
				InputPath:   input,
				OutputPath:  output,
				DeleteInput: deleteInput,
				AWS:         cfg.AWS,
				GCP:         cfg.GCP,
				Azure:       cfg.Azure,
				Vault:       cfg.Vault,
			})
			if err != nil {
				return err
			}

			if isVault {
				fmt.Printf("BLS key imported into Vault at: %s/keys/%s\n", cfg.Vault.MountPath, cfg.Vault.KeyName)
			} else {
				fmt.Printf("Encrypted key written to: %s\n", output)
			}
			fmt.Printf("BLS public key (hex):     %s\n", pkHex)
			fmt.Println()
			fmt.Println("IMPORTANT: confirm the public key above matches your on-chain registration")
			fmt.Println("before using this encrypted key.  Check with: avalanche-cli node list")
			if deleteInput {
				fmt.Printf("Plaintext key securely deleted: %s\n", input)
			}
			return nil
		},
	}

	commonKMSFlags(cmd)
	cmd.Flags().String("input", "", "path to the plaintext signer.key file (required)")
	cmd.Flags().String("output", "", "path to write the encrypted key blob (not needed for vault backend)")
	cmd.Flags().Bool("delete-input", false, "securely overwrite and delete the plaintext key after migration")
	_ = cmd.MarkFlagRequired("input")

	return cmd
}

// ── backend factory ───────────────────────────────────────────────────────────

func buildBackend(cfg config.Config, log *slog.Logger) (backend.Backend, error) {
	switch cfg.Backend {
	case config.BackendMemory:
		log.Warn("using in-memory backend — DO NOT use in production")
		return memory.New()
	case config.BackendAWSKMS:
		return awskms.New(cfg.AWS, log)
	case config.BackendGCPKMS:
		return gcpkms.New(cfg.GCP, log)
	case config.BackendAzureKV:
		return azurekv.New(cfg.Azure, log)
	case config.BackendVault:
		return vaultbackend.New(cfg.Vault, log)
	default:
		return nil, fmt.Errorf("unknown backend %q — valid options: memory, aws-kms, gcp-kms, azure-kv", cfg.Backend)
	}
}
