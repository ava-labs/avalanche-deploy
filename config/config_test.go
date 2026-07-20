// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package config

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTemp(t *testing.T, contents string) string {
	t.Helper()
	f := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(f, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

// TestLoadRejectsUnknownKey guards the strict-parsing behavior: a misspelled
// key must be an error, not silently ignored (which would leave the backend at
// its default and start a dev in-memory signer unnoticed).
func TestLoadRejectsUnknownKey(t *testing.T) {
	f := writeTemp(t, "backend: aws-kms\nbackedn: oops\n") // note the typo'd second key
	if _, err := Load(f); err == nil {
		t.Fatal("expected Load to reject an unknown/misspelled key, got nil error")
	}
}

// TestLoadAcceptsAllBackendKeys asserts every key the docs and e2e scripts emit
// (across all backend blocks) parses under KnownFields. Guards against strict
// parsing rejecting a legitimate config if a struct tag ever drifts.
func TestLoadAcceptsAllBackendKeys(t *testing.T) {
	cfgYAML := `backend: aws-kms
listen: 127.0.0.1
port: 50051
aws:
  region: us-east-1
  kms_key_id: arn:aws:kms:us-east-1:1:key/abc
  encrypted_bls_key_path: /tmp/bls.key.enc
  endpoint_url: http://localhost:4566
nitro:
  region: us-east-2
  eif_path: /home/ec2-user/remote-signer.eif
  kms_key_id: arn:aws:kms:us-east-2:1:key/abc
  encrypted_bls_key_path: /tmp/bls.key.enc
  cpu_count: 2
  memory_mib: 512
  enclave_cid: 16
gcp:
  project: p
  location: l
  key_ring: r
  key_name: k
  encrypted_bls_key_path: /tmp/bls.key.enc
azure:
  vault_url: https://v.vault.azure.net
  key_name: k
  encrypted_bls_key_path: /tmp/bls.key.enc
vault:
  address: http://127.0.0.1:8200
  mount_path: bls
  key_name: validator
  auth_method: token
  token: s.redacted
  kubernetes_role: r
  kubernetes_jwt_path: /var/run/secrets/token
  aws_role: r
`
	f := writeTemp(t, cfgYAML)
	cfg, err := Load(f)
	if err != nil {
		t.Fatalf("Load rejected a valid all-backend config: %v", err)
	}
	if cfg.Backend != BackendAWSKMS {
		t.Errorf("backend = %q, want %q", cfg.Backend, BackendAWSKMS)
	}
	if cfg.Vault.MountPath != "bls" || cfg.Nitro.EnclaveCID != 16 {
		t.Errorf("nested values did not parse: vault.mount_path=%q nitro.enclave_cid=%d",
			cfg.Vault.MountPath, cfg.Nitro.EnclaveCID)
	}
}

// TestLoadAcceptsEmptyOrCommentsOnly guards against the strict-decoder EOF
// regression: a zero-byte file or one with every line commented out is a valid
// "all defaults" config, not a parse error (yaml.Decoder reports it as io.EOF
// where yaml.Unmarshal accepted it silently).
func TestLoadAcceptsEmptyOrCommentsOnly(t *testing.T) {
	for name, contents := range map[string]string{
		"empty":         "",
		"comments-only": "# backend: aws-kms\n# port: 50051\n",
	} {
		t.Run(name, func(t *testing.T) {
			cfg, err := Load(writeTemp(t, contents))
			if err != nil {
				t.Fatalf("Load(%s config) failed: %v", name, err)
			}
			if cfg.Backend != BackendMemory || cfg.Port != 50051 {
				t.Fatalf("expected defaults, got backend=%q port=%d", cfg.Backend, cfg.Port)
			}
		})
	}
}

// TestAddrIPv6 — Addr must produce a dialable address for IPv6 listens.
func TestAddrIPv6(t *testing.T) {
	cfg := Config{Listen: "::1", Port: 50051}
	if got, want := cfg.Addr(), "[::1]:50051"; got != want {
		t.Fatalf("Addr() = %q, want %q", got, want)
	}
	cfg = Config{Listen: "127.0.0.1", Port: 50051}
	if got, want := cfg.Addr(), "127.0.0.1:50051"; got != want {
		t.Fatalf("Addr() = %q, want %q", got, want)
	}
}

// TestInvalidPortEnvIsAnError — a malformed PORT must fail loudly, not fall
// back to the default port with AvalancheGo dialing into the void.
func TestInvalidPortEnvIsAnError(t *testing.T) {
	for _, bad := range []string{"5O051", "0", "-1", "70000"} {
		t.Setenv("PORT", bad)
		if _, err := Load(""); err == nil {
			t.Fatalf("PORT=%q: expected error, got nil", bad)
		}
	}
	t.Setenv("PORT", "50052")
	cfg, err := Load("")
	if err != nil || cfg.Port != 50052 {
		t.Fatalf("PORT=50052: got port=%d err=%v", cfg.Port, err)
	}
}

// TestBackendCaseInsensitive — the backend name must select the same backend
// from every config source regardless of case.
func TestBackendCaseInsensitive(t *testing.T) {
	f := writeTemp(t, "backend: AWS-KMS\n")
	cfg, err := Load(f)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Backend != BackendAWSKMS {
		t.Fatalf("YAML backend AWS-KMS: got %q", cfg.Backend)
	}
	t.Setenv("BACKEND", " Vault ")
	if cfg, _ = Load(""); cfg.Backend != BackendVault {
		t.Fatalf("env BACKEND=' Vault ': got %q", cfg.Backend)
	}
	if got := ParseBackend("Aws-Nitro"); got != BackendAWSNitro {
		t.Fatalf("ParseBackend(Aws-Nitro) = %q", got)
	}
}

// TestVaultKubernetesJWTPathEnv — the one VaultConfig field that was missing
// from applyEnv (and the one Kubernetes deployments configure via env).
func TestVaultKubernetesJWTPathEnv(t *testing.T) {
	t.Setenv("VAULT_KUBERNETES_JWT_PATH", "/var/run/secrets/custom/token")
	cfg, err := Load("")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Vault.KubernetesJWTPath != "/var/run/secrets/custom/token" {
		t.Fatalf("KubernetesJWTPath = %q", cfg.Vault.KubernetesJWTPath)
	}
}
