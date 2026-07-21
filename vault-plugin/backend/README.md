# backend/

> The Vault secrets-engine backend for the `vault-plugin-bls` binary — defines the key/sign endpoints and performs BLS12-381 operations in-process.

## What this is

The implementation half of the standalone `vault-plugin/` module (a **separate Go module / standalone binary**, not part of the root signer). Package `backend` builds the `logical.Backend` that Vault serves: it registers the secrets-engine paths and handles each request. BLS keys are stored as a hex-encoded 32-byte scalar in Vault's encrypted storage; generation, public-key derivation, and signing all run here, so plaintext key material is never returned over the API.

## Contents

- `backend.go` — `Factory` (the function `main.go` registers) and the `backend` struct; assembles the path list and the help text.
- `path_keys.go` — the `keys/<name>/{generate, import, public-key}` paths, DELETE on bare `keys/<name>` (rotation), plus storage helpers (`loadKey`) and existence checks.
- `path_sign.go` — the `keys/<name>/{sign, sign-pop}` paths and the hardcoded AvalancheGo DSTs.
- `bls.go` — blst (BLS12-381) primitives: `generateKey`, `publicKeyHex`, `sign`, `deserialize`.

## How it works

`Factory` (in `backend.go`) returns a `framework.Backend` of type `logical.TypeLogical`, appending the paths from `pathKeys(b)` and `pathSign(b)`. Each endpoint maps Create/Update operations to a handler:

- **`keys/<name>/generate`** → `handleGenerate`: draws 32 bytes of entropy, calls `blst.KeyGen` (HKDF), stores the hex scalar under the `keys/` storage prefix, and returns only `name` + `public_key`. Refuses to overwrite an existing key.
- **`keys/<name>/import`** → `handleImport`: accepts a hex-encoded 32-byte scalar (used by `keytool migrate --backend vault`), validates it by deriving the public key, then stores it. Also refuses to overwrite.
- **`keys/<name>/public-key`** → `handlePublicKey`: loads the scalar and returns the 48-byte compressed **G1** public key as hex.
- **`keys/<name>/sign`** → `handleSign`: signs the hex `message` and returns the 96-byte compressed **G2** signature. DST defaults to the Warp sign DST (`BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`) but can be overridden via the `dst` field.
- **`keys/<name>/sign-pop`** → `handleSignPoP`: signs with the proof-of-possession DST (`BLS_POP_...RO_POP_`) unconditionally — no `dst` field.

All signing flows through `doSign`, which loads the scalar via `loadKey` and calls `bls.go`'s `sign`. In `bls.go`, `sign` decodes the message and DST, then computes `blst.P2Affine.Sign(sk, msg, dst)`; `deserialize` enforces the 32-byte scalar length before any operation. The scalar is read back out of storage only inside this process — it is never placed in a response.

## Build & run

Built as part of the `vault-plugin/` module, not standalone — see [`../README.md`](../README.md). CGO is mandatory because blst uses cgo:

```bash
cd ..                                 # into vault-plugin/ (the module root)
CGO_ENABLED=1 go build -trimpath -o vault-plugin-bls .
```

The package is wired into Vault through `main.go`'s `plugin.ServeMultiplex(... BackendFactoryFunc: backend.Factory ...)`; you do not run this package directly. Endpoints become available after the binary is registered and `vault secrets enable -path=bls vault-plugin-bls`.

## Troubleshooting

- **`key "<name>" not found` on sign/public-key** → no key was generated/imported at that name, or the signer's `vault.key_name` doesn't match. Run `vault write -f bls/keys/<name>/generate` (or import), and confirm the configured key name.
- **`key "<name>" already exists` on generate/import** → both handlers refuse to overwrite; `vault delete bls/keys/<name>` first if you really intend to replace it.
- **`expected 32-byte key` / `invalid BLS scalar`** → an import value that isn't a valid 32-byte hex scalar (`import` requires a 64-char hex string). Re-export the scalar correctly.
- **Warp/ICM signatures rejected by the network, but PoP/registration work** → a wrong `dst` was passed to `sign`. AvalancheGo uses the proof-of-possession ciphersuite (`...RO_POP_`); leave `dst` unset to use the built-in default, or pass the PoP DST exactly.
- **cgo/linker errors building the parent binary** → `CGO_ENABLED=1` not set or no C compiler; blst (used by `bls.go`) needs cgo.

## Related

- [`../README.md`](../README.md) — the plugin binary: build, register with Vault, and enable at `bls/`.
- [`../../api/vault/`](../../api/vault/) — the signer-side client that calls these endpoints (`public-key`, `sign`, `sign-pop`) over the Vault HTTP API.
- [`../../internal/blstutil/`](../../internal/blstutil/) — the root module's canonical DST definitions, cross-checked against AvalancheGo (the DSTs here mirror those).
- [`../../docs/vault.md`](../../docs/vault.md) — full Vault setup and security model.
