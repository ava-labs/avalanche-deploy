# api/gcpkms/

> `Backend` implementation that decrypts a BLS key blob with Google Cloud KMS at startup and signs in-process.

> **🧪 Experimental**: not yet validated by the [end-to-end suite](../../docs/e2e.md) against real GCP infrastructure; may be modified at any time. Do not rely on it for production validators until an E2E run has passed.

## What this is
The `gcp-kms` backend. At boot it reads the encrypted key blob from disk and calls Cloud KMS `Decrypt` to recover the 32-byte BLS scalar into host memory; signing then happens locally via blst. It is one of the `api.Backend` providers behind `signerserver/`, selected when `backend: gcp-kms`.

## Contents
- `gcpkms.go` — `Backend` type, `New`/`newWithClient` (load + decrypt), `resourceName`, plus `Encrypt`/`NewKMSClient` helpers for keytool.
- `gcpkms_test.go` — unit tests using an in-memory XOR mock `kmsClient` (no real GCP).

## How it works
`New` creates a `KeyManagementClient` (Application Default Credentials) and calls `newWithClient`, which reads `cfg.EncryptedBLSKeyPath` and issues `Decrypt` against `resourceName(cfg)` — `projects/{project}/locations/{location}/keyRings/{keyRing}/cryptoKeys/{keyName}`. The plaintext is validated by `backendFromBytes` (32-byte scalar) and the public key is cached. `Sign` uses `blstutil.Sign(skBytes, msg, dstSign)` and `SignProofOfPossession` uses `dstPopProve` (from `blstutil.DSTSign`/`DSTPoP`). Unlike the other cloud backends this one retains the KMS client; `Close` zeroes the key *and* closes the client.

## Troubleshooting
- `PermissionDenied` on decrypt → the service account lacks `cloudkms.cryptoKeyVersions.useToDecrypt`. Grant `roles/cloudkms.cryptoKeyDecrypter` (add the Encrypter role for keytool).
- `NotFound` for the crypto key → one of `project`/`location`/`key_ring`/`key_name` is wrong; the `resourceName` must exactly match the key used to encrypt the blob.
- `FailedPrecondition` / decrypt mismatch → blob was encrypted under a different key or is corrupt; re-encrypt via `keytool`.
- "creating GCP KMS client" / auth errors → no ADC available; set `GOOGLE_APPLICATION_CREDENTIALS` or run on a GCE/GKE identity with the KMS role.
- "reading encrypted key" → `encrypted_bls_key_path` wrong or unreadable.
- "expected 32-byte BLS scalar" / "invalid BLS key material" → wrong file or non-KMS ciphertext decrypted to non-key bytes.

## Related
- [`docs/gcp-kms.md`](../../docs/gcp-kms.md) — end-to-end setup (key ring, IAM, generate/migrate, GCE/GKE).
- [`../../internal/blstutil`](../../internal/blstutil/) — DST constants and BLS signing.
- [`../`](../) — the `Backend` interface and provider overview.
