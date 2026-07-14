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
