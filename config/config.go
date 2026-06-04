// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package config defines the top-level configuration for avalanche-kms-signer.
//
// Precedence (highest to lowest):
//  1. CLI flags
//  2. Environment variables  (KEY becomes --key, e.g. BACKEND → --backend)
//  3. Config file (YAML)
//
// Example config file:
//
//	backend: memory      # memory | aws-kms | gcp-kms | azure-kv | vault | aws-nitro
//	port:    50051
//	listen:  127.0.0.1
//
//	aws:
//	  region:                 us-east-1
//	  kms_key_id:             arn:aws:kms:us-east-1:123456789:key/abc-def
//	  encrypted_bls_key_path: /etc/avalanche/bls.key.enc
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// BackendType enumerates the supported signing backends.
type BackendType string

const (
	BackendMemory   BackendType = "memory"    // in-process, dev/test only
	BackendAWSKMS   BackendType = "aws-kms"   // Phase 1
	BackendGCPKMS   BackendType = "gcp-kms"   // Phase 1
	BackendAzureKV  BackendType = "azure-kv"  // Phase 1
	BackendVault    BackendType = "vault"      // Phase 3
	BackendAWSNitro BackendType = "aws-nitro"  // Phase 2
)

// Config is the root configuration object.
type Config struct {
	// Backend selects which signing backend to use.
	Backend BackendType `yaml:"backend"`

	// Listen is the IP address the gRPC server binds to.
	Listen string `yaml:"listen"`

	// Port is the TCP port the gRPC server listens on.
	Port int `yaml:"port"`

	// AWS holds configuration for the aws-kms and aws-nitro backends.
	AWS AWSConfig `yaml:"aws"`

	// GCP holds configuration for the gcp-kms backend.
	GCP GCPConfig `yaml:"gcp"`

	// Azure holds configuration for the azure-kv backend.
	Azure AzureConfig `yaml:"azure"`

	// Vault holds configuration for the vault backend.
	Vault VaultConfig `yaml:"vault"`
}

// AWSConfig holds AWS-specific settings.
type AWSConfig struct {
	Region              string `yaml:"region"`
	KMSKeyID            string `yaml:"kms_key_id"`
	EncryptedBLSKeyPath string `yaml:"encrypted_bls_key_path"`
	// EndpointURL overrides the AWS KMS endpoint. Used for LocalStack and other
	// local testing environments. Leave empty in production.
	EndpointURL string `yaml:"endpoint_url"`
}

// GCPConfig holds GCP-specific settings.
type GCPConfig struct {
	Project             string `yaml:"project"`
	Location            string `yaml:"location"`
	KeyRing             string `yaml:"key_ring"`
	KeyName             string `yaml:"key_name"`
	EncryptedBLSKeyPath string `yaml:"encrypted_bls_key_path"`
}

// AzureConfig holds Azure-specific settings.
type AzureConfig struct {
	VaultURL            string `yaml:"vault_url"`
	KeyName             string `yaml:"key_name"`
	EncryptedBLSKeyPath string `yaml:"encrypted_bls_key_path"`
}

// VaultConfig holds HashiCorp Vault settings.
type VaultConfig struct {
	// Address is the Vault server URL, e.g. https://vault.internal:8200
	Address string `yaml:"address"`

	// MountPath is where the BLS plugin is mounted. Defaults to "bls".
	MountPath string `yaml:"mount_path"`

	// KeyName is the name of the BLS key within the plugin.
	KeyName string `yaml:"key_name"`

	// AuthMethod selects how to authenticate: token | kubernetes | aws-iam
	AuthMethod string `yaml:"auth_method"`

	// Token is used when AuthMethod == "token".
	Token string `yaml:"token"`

	// KubernetesRole is the Vault role name for Kubernetes auth.
	KubernetesRole string `yaml:"kubernetes_role"`

	// KubernetesJWTPath is the path to the service account JWT token.
	// Defaults to /var/run/secrets/kubernetes.io/serviceaccount/token.
	KubernetesJWTPath string `yaml:"kubernetes_jwt_path"`

	// AWSRole is the Vault role name for AWS IAM auth.
	AWSRole string `yaml:"aws_role"`
}

// Defaults returns a Config populated with sensible defaults.
func Defaults() Config {
	return Config{
		Backend: BackendMemory,
		Listen:  "127.0.0.1",
		Port:    50051,
	}
}

// Addr returns the combined listen address for the gRPC server.
func (c *Config) Addr() string {
	return fmt.Sprintf("%s:%d", c.Listen, c.Port)
}

// Load merges a YAML file (if path is non-empty) and then applies
// environment-variable overrides.  Flags are applied separately in main.
func Load(path string) (Config, error) {
	cfg := Defaults()

	if path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return cfg, fmt.Errorf("reading config file %q: %w", path, err)
		}
		if err := yaml.Unmarshal(data, &cfg); err != nil {
			return cfg, fmt.Errorf("parsing config file %q: %w", path, err)
		}
	}

	applyEnv(&cfg)
	return cfg, nil
}

// applyEnv applies environment-variable overrides.
// The convention mirrors cube-signer-sidecar: upper-case the YAML key and
// replace "-" with "_".  Examples:
//
//	BACKEND         → cfg.Backend
//	LISTEN          → cfg.Listen
//	PORT            → cfg.Port
//	AWS_REGION      → cfg.AWS.Region
//	AWS_KMS_KEY_ID  → cfg.AWS.KMSKeyID
func applyEnv(cfg *Config) {
	if v := os.Getenv("BACKEND"); v != "" {
		cfg.Backend = BackendType(strings.ToLower(v))
	}
	if v := os.Getenv("LISTEN"); v != "" {
		cfg.Listen = v
	}
	if v := os.Getenv("PORT"); v != "" {
		if p, err := strconv.Atoi(v); err == nil {
			cfg.Port = p
		}
	}

	// AWS
	if v := os.Getenv("AWS_REGION"); v != "" {
		cfg.AWS.Region = v
	}
	if v := os.Getenv("AWS_KMS_KEY_ID"); v != "" {
		cfg.AWS.KMSKeyID = v
	}
	if v := os.Getenv("AWS_ENDPOINT_URL"); v != "" {
		cfg.AWS.EndpointURL = v
	}
	if v := os.Getenv("AWS_ENCRYPTED_BLS_KEY_PATH"); v != "" {
		cfg.AWS.EncryptedBLSKeyPath = v
	}

	// GCP
	if v := os.Getenv("GCP_PROJECT"); v != "" {
		cfg.GCP.Project = v
	}
	if v := os.Getenv("GCP_LOCATION"); v != "" {
		cfg.GCP.Location = v
	}
	if v := os.Getenv("GCP_KEY_RING"); v != "" {
		cfg.GCP.KeyRing = v
	}
	if v := os.Getenv("GCP_KEY_NAME"); v != "" {
		cfg.GCP.KeyName = v
	}
	if v := os.Getenv("GCP_ENCRYPTED_BLS_KEY_PATH"); v != "" {
		cfg.GCP.EncryptedBLSKeyPath = v
	}

	// Azure
	if v := os.Getenv("AZURE_VAULT_URL"); v != "" {
		cfg.Azure.VaultURL = v
	}
	if v := os.Getenv("AZURE_KEY_NAME"); v != "" {
		cfg.Azure.KeyName = v
	}
	if v := os.Getenv("AZURE_ENCRYPTED_BLS_KEY_PATH"); v != "" {
		cfg.Azure.EncryptedBLSKeyPath = v
	}

	// Vault
	if v := os.Getenv("VAULT_ADDR"); v != "" {
		cfg.Vault.Address = v
	}
	if v := os.Getenv("VAULT_MOUNT_PATH"); v != "" {
		cfg.Vault.MountPath = v
	}
	if v := os.Getenv("VAULT_KEY_NAME"); v != "" {
		cfg.Vault.KeyName = v
	}
	if v := os.Getenv("VAULT_AUTH_METHOD"); v != "" {
		cfg.Vault.AuthMethod = v
	}
	if v := os.Getenv("VAULT_TOKEN"); v != "" {
		cfg.Vault.Token = v
	}
	if v := os.Getenv("VAULT_KUBERNETES_ROLE"); v != "" {
		cfg.Vault.KubernetesRole = v
	}
	if v := os.Getenv("VAULT_AWS_ROLE"); v != "" {
		cfg.Vault.AWSRole = v
	}
}
