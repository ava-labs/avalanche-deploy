# api/awskms/

> `Backend` implementation that decrypts a BLS key blob with AWS KMS at startup and signs in-process.

## What this is
The `aws-kms` backend. At boot it reads the encrypted key blob from disk and calls `kms:Decrypt` to recover the 32-byte BLS scalar into host memory; all signing then happens locally via blst with no further KMS calls. It sits behind `signerserver/` as one of the `api.Backend` providers, selected when `backend: aws-kms`.

## Contents
- `awskms.go` — `Backend` type, `New`/`newWithClient` (load + decrypt), `Encrypt` and `NewKMSClient` helpers for keytool.
- `awskms_test.go` — unit tests using an in-memory XOR mock `kmsDecryptor` (no real AWS).

## How it works
`New` builds a `*kms.Client` via `NewKMSClient(cfg)` then calls `newWithClient`, which reads `cfg.EncryptedBLSKeyPath` and issues `Decrypt` with `cfg.KMSKeyID` and `SymmetricDefault`. The plaintext goes through `backendFromBytes`, which validates the 32-byte scalar (`blstutil.ValidateSecretKey`) and caches the derived public key. `Sign` calls `blstutil.Sign(skBytes, msg, dstSign)` and `SignProofOfPossession` uses `dstPopProve` — both sourced from `blstutil.DSTSign`/`DSTPoP`. `Close` zeroes the in-memory key. The blob is raw KMS ciphertext (the key id is not stored in the blob — it comes from config). If `cfg.EndpointURL` is set, `NewKMSClient` swaps in static `test/test` credentials and points at that endpoint for LocalStack.

## Troubleshooting
- `AccessDeniedException` on decrypt → the instance/role lacks `kms:Decrypt` on the key, or the key policy omits the principal. Grant `kms:Decrypt` (and `kms:Encrypt`/`GenerateDataKey` for keytool).
- `IncorrectKeyException` / `InvalidCiphertextException` → `kms_key_id` does not match the key the blob was encrypted under, or the blob is corrupt/wrong file. Re-encrypt with `keytool` under the correct key.
- "reading encrypted key" error → `encrypted_bls_key_path` is wrong or unreadable by the signer's user.
- STS/credential or region errors at startup → `aws_region` unset/wrong, or no credentials in the chain (env, `~/.aws`, instance profile, ECS task role).
- "expected 32-byte BLS scalar" / "invalid BLS key material" → blob decrypted to non-key bytes (wrong file or non-KMS ciphertext).
- Hitting real AWS during local tests → set `endpoint_url`/`--aws-endpoint-url` (e.g. `http://localhost:4566`) so static creds and the LocalStack endpoint are used.

## Related
- [`docs/aws-kms.md`](../../docs/aws-kms.md) — end-to-end setup (key, IAM, generate/migrate, EC2/ECS).
- [`../../internal/blstutil`](../../internal/blstutil/) — DST constants and BLS signing.
- [`../`](../) — the `Backend` interface and provider overview.
- [`../awsnitro/`](../awsnitro/) — stronger isolation variant where the key never reaches host memory.
