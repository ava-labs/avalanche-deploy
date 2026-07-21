# vault-plugin/

> Standalone HashiCorp Vault secrets plugin that holds a BLS12-381 key inside Vault and signs with it, so the private key never leaves Vault's process.

## What this is

A custom HashiCorp Vault secrets-engine plugin, built as its **own Go module and standalone binary** (`vault-plugin-bls`) — separate from the root signer module. It is dropped into the Vault server's `plugin_directory`, registered, and mounted at `bls/`. The BLS scalar lives in Vault's encrypted storage; generation, public-key derivation, and signing all happen inside this process, so plaintext key material never crosses an API boundary. The signer's `api/vault/` backend is the client that calls this plugin's endpoints over the Vault HTTP API.

## Contents

- `main.go` — plugin entry point; serves `backend.Factory` over Vault's plugin RPC via `plugin.ServeMultiplex`.
- `go.mod` / `go.sum` — the separate module (`.../vault-plugin`), depending on `hashicorp/vault/sdk` and `supranational/blst`.
- `Dockerfile` — CGO build of the `vault-plugin-bls` binary, exported from a `scratch` stage for extraction.
- `backend/` — the secrets-engine backend: path/endpoint definitions and the blst signing logic (see `backend/README.md`).

## How it works

`main.go` calls `plugin.ServeMultiplex` with `BackendFactoryFunc: blssigner.Factory`; Vault launches the binary as a subprocess and speaks to it over go-plugin RPC. The factory builds a `logical.TypeLogical` backend whose paths (`keys/<name>/generate`, `/import`, `/public-key`, `/sign`, `/sign-pop`, and DELETE on bare `keys/<name>` for rotation) are defined in `backend/`. Keys are persisted under the `keys/` storage prefix as a hex-encoded 32-byte scalar; only the 48-byte compressed G1 public key and 96-byte compressed G2 signatures are ever returned. blst (BLS12-381) requires **cgo**, so this binary must be built with `CGO_ENABLED=1`.

## Build & run

This is a separate module — build from inside `vault-plugin/`:

```bash
cd vault-plugin
CGO_ENABLED=1 go build -trimpath -o vault-plugin-bls .
```

Or via Docker (extracts the linux binary):

```bash
docker build -t vault-plugin-bls ./vault-plugin/
docker create --name tmp vault-plugin-bls
docker cp tmp:/vault-plugin-bls ./vault-plugin-bls
docker rm tmp
```

Register and enable it with Vault (binary must live in the server's `plugin_directory`):

```bash
SHA=$(sha256sum vault-plugin-bls | cut -d' ' -f1)
vault plugin register -sha256=$SHA secret vault-plugin-bls
vault secrets enable -path=bls vault-plugin-bls   # mounts at bls/
```

Then generate a key the signer can use:

```bash
vault write -f bls/keys/validator-1/generate   # returns public_key; scalar stays in Vault
```

## Troubleshooting

- **`undefined: ...` / cgo or linker errors at build** → `CGO_ENABLED=1` was not set or there is no C compiler; blst needs cgo. Install `gcc`/`musl-dev` (the Dockerfile does this) and rebuild.
- **`vault plugin register` fails with a SHA256 mismatch** → the registered hash doesn't match the binary actually in `plugin_directory`. Re-run `sha256sum` against the deployed file and re-register.
- **`secrets enable` errors with "plugin not found"** → binary isn't in Vault's `plugin_directory`, or `plugin_directory` isn't set in the Vault server config. Copy the binary there and restart Vault.
- **Plugin won't start / "fork/exec ... permission denied"** → binary isn't executable, or SELinux/AppArmor blocked exec from the plugin dir. `chmod +x` and check the host's exec policy.
- **Wrong mount path** → the signer defaults to mount path `bls`; if you enable at a different path, set `vault.mount_path` in the signer config to match.

## Related

- [`../api/vault/`](../api/vault/) — the signer-side client of this plugin; makes the `public-key` / `sign` / `sign-pop` HTTP calls and never holds key material.
- [`backend/`](./backend/) — endpoint implementations (generate, import, public-key, sign, sign-pop, delete).
- [`../docs/vault.md`](../docs/vault.md) — full setup guide: install Vault, build/register the plugin, generate a key, auth methods (token / kubernetes / aws-iam), and the security model.
- [`../AGENTS.md`](../AGENTS.md) — repo map and the four-module layout.
