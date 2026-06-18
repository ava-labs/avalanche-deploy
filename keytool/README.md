# keytool/

> Offline key management: generate a new BLS key or migrate an existing one into the chosen KMS backend.

## What this is
This package backs the `keytool generate` and `keytool migrate` CLI subcommands. It produces the encrypted key blob (or in-Vault key) that the `serve` command later decrypts at startup. It runs out-of-band on an operator workstation or bastion, not as part of the running signer, and prints the resulting public key for on-chain verification.

## Contents
- `keytool.go` — `GenerateOpts`/`Generate`, `MigrateOpts`/`Migrate`, the `encryptForBackend` dispatcher, Vault helpers (`vaultGenerate`, `vaultImport`, `vaultClient`), and `secureDelete`.

## How it works
`Generate` makes a fresh scalar via `generateBLSKey` (32 random bytes → `blstutil.KeyGen`), derives the public key with `blstutil.PublicKey`, encrypts the scalar through `encryptForBackend`, and writes it `0600` to `OutputPath`. `Migrate` instead reads an existing plaintext `signer.key`, enforces a 32-byte length and `blstutil.ValidateSecretKey`, then encrypts and writes it; with `DeleteInput` it `secureDelete`s the original (zero-overwrite + remove). Both return the hex compressed public key. `encryptForBackend` switches on `BackendType` and calls the provider's envelope-encrypt helper — `awskms.Encrypt`, `gcpkms.Encrypt`, or `azurekv.Encrypt` (GCP key path is assembled from `Project/Location/KeyRing/KeyName`). The `vault` backend is special-cased before encryption: `vaultGenerate` writes `<mount>/keys/<name>/generate` and `vaultImport` posts the hex key to `<mount>/keys/<name>/import`, so the key never leaves Vault and no file is produced.

## Troubleshooting
- `--output is required for backend "..."`: every backend except `vault` writes a file; pass `--output` (enforced in `main`, not here).
- `expected 32-byte BLS scalar ... got N bytes` / `does not contain a valid BLS scalar`: the `--input` file isn't a raw AvalancheGo `signer.key`; don't point at a hex or PEM file.
- `secure delete ... failed: ... — MANUAL DELETION REQUIRED`: the encrypted blob was written but the plaintext remains; delete it by hand. Note `secureDelete` is best-effort and not safe against SSD wear-levelling or snapshots.
- `vault.token must be set for keytool`: `vaultClient` only supports token auth; set `vault.token`/`VAULT_TOKEN` even if `serve` uses kubernetes/aws-iam.
- Public key doesn't match registration: the tool prints a reminder to verify against `avalanche-cli node list` before deleting plaintext or starting the node — do it.

## Related
- [../internal/blstutil/](../internal/blstutil/) — key gen, validation, public-key derivation.
- [../api/](../api/) — the provider `Encrypt`/`NewKMSClient` helpers invoked here.
- [../config/](../config/) — the per-provider config structs in `*Opts`.
- [../vault-plugin/](../vault-plugin/) — serves the `keys/.../generate` and `import` endpoints.
- [../docs/architecture.md](../docs/architecture.md) and the per-backend guides in [../docs/](../docs/).
