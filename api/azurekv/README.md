# api/azurekv/

> `Backend` implementation that unwraps a BLS key blob with an Azure Key Vault RSA key at startup and signs in-process.

> **🧪 Experimental**: not yet validated by the [end-to-end suite](../../docs/e2e.md) against real Azure infrastructure; may be modified at any time. Do not rely on it for production validators until an E2E run has passed.

## What this is
The `azure-kv` backend. At boot it reads the encrypted key blob from disk and calls Key Vault's `Decrypt` (RSA-OAEP-256) to unwrap the 32-byte BLS scalar into host memory; signing then happens locally via blst. It is one of the `api.Backend` providers behind `signerserver/`, selected when `backend: azure-kv`.

## Contents
- `azurekv.go` — `Backend` type, `New`/`newWithClient` (load + decrypt), plus `Encrypt`/`NewKVClient` helpers for keytool.
- `azurekv_test.go` — unit tests using an in-memory XOR mock `kvClient` (no real Azure).

## How it works
`New` builds an `azidentity.NewDefaultAzureCredential` and an `azkeys.NewClient(cfg.VaultURL, ...)`, then `newWithClient` reads `cfg.EncryptedBLSKeyPath` and calls `Decrypt(cfg.KeyName, "", ...)` with algorithm `EncryptionAlgorithmRSAOAEP256` (empty version string = latest). The unwrapped plaintext is validated by `backendFromBytes` (32-byte scalar) and the public key cached. `Sign` uses `blstutil.Sign(skBytes, msg, dstSign)` and `SignProofOfPossession` uses `dstPopProve` (from `blstutil.DSTSign`/`DSTPoP`). `Close` zeroes the in-memory key. Note the Key Vault object is an RSA wrapping key — the BLS key itself is never stored in Key Vault, only wrapped by it.

## Troubleshooting
- `Forbidden` / `AKV10032` on decrypt → the identity lacks the **Decrypt** key permission. Grant a Key Vault access policy / RBAC role with `decrypt` (add `encrypt` for keytool).
- `KeyNotFound` → `key_name` is wrong or the key was rotated/deleted; the unwrap key must be the one used to wrap the blob.
- `DefaultAzureCredential` errors at startup → no usable credential (set env service-principal vars, use managed identity on the VM/AKS, or `az login` locally).
- Wrong `vault_url` → malformed host or trailing-path issues; use the form `https://<name>.vault.azure.net/`.
- Decrypt succeeds but "expected 32-byte BLS scalar" / "invalid BLS key material" → blob was wrapped with a different RSA key/algorithm or is corrupt; re-encrypt via `keytool` (algorithm is fixed at RSA-OAEP-256).
- "reading encrypted key" → `encrypted_bls_key_path` wrong or unreadable.

## Related
- [`docs/azure-kv.md`](../../docs/azure-kv.md) — end-to-end setup (vault, RSA key, access policies, VM/AKS).
- [`../../internal/blstutil`](../../internal/blstutil/) — DST constants and BLS signing.
- [`../`](../) — the `Backend` interface and provider overview.
