# api/vault/

> `Backend` implementation that delegates BLS signing to a HashiCorp Vault plugin over HTTP — the key never leaves Vault.

## What this is
The `vault` backend. Unlike the cloud-KMS backends, the BLS private key never enters the signer's process: signing happens inside the Vault BLS secrets plugin, and this backend makes authenticated HTTP API calls to request signatures. It is one of the `api.Backend` providers behind `signerserver/`, selected when `backend: vault`, and pairs with the separate `vault-plugin/` module.

## Contents
- `vault.go` — `Backend` type, auth (`authenticate`), background token renewal (`renewTokenLoop`/`tokenTTL`), public-key fetch, and `requestSign`.

## How it works
`New` builds a `vault.Client` for `cfg.Address`, calls `authenticate` (method `token` | `kubernetes` | `aws-iam`), then reads `<mountPath>/keys/<keyName>/public-key` to cache the 48-byte key. `mountPath` defaults to `bls`. `Sign` and `SignProofOfPossession` write to `.../sign` and `.../sign-pop` respectively, sending the hex message plus a hex `dst` — `dstSign`/`dstPopProve` here are the hex encodings of `blstutil.DSTSign`/`DSTPoP`, so the DST split is enforced by the *caller* and honored by the plugin. A background goroutine renews the token at 75% of its TTL (`renewFraction`) and re-authenticates if renewal fails; root/non-renewable tokens are detected and skipped. For Kubernetes auth the service-account JWT is re-read from disk on every auth so rotated tokens are picked up. `Close` cancels the renewal goroutine (no key material to zero).

## Troubleshooting
- `permission denied` (403) on read/write → the Vault token/policy lacks access to `<mount>/keys/<name>/*`. Attach a policy granting read on `public-key` and update/create on `sign`/`sign-pop`.
- `no handler for route ".../public-key"` / 404 → plugin not mounted, or `mount_path` mismatch (default `bls`); confirm the `vault-plugin-bls` plugin is registered and enabled at that path.
- "auth_method=token requires vault.token" → set `vault.token`, or switch to `kubernetes`/`aws-iam`.
- Signing stops working after ~1h → token expired and renewal failed; check `kubernetes_role`/`aws_role` validity and that the renewal goroutine logs renew/re-auth (a non-renewable token is skipped by design).
- "reading kubernetes JWT" → `kubernetes_jwt_path` wrong (default `/var/run/secrets/kubernetes.io/serviceaccount/token`); only valid inside a pod.
- "unknown auth_method" → must be one of `token`, `kubernetes`, `aws-iam`.
- "expected 48-byte public key" / "expected 96-byte signature" → plugin returned malformed data or the key name does not exist in the plugin.

## Related
- [`docs/vault.md`](../../docs/vault.md) — end-to-end setup (install Vault, build/register plugin, generate key).
- [`../../vault-plugin`](../../vault-plugin/) — the BLS secrets plugin that holds the key and performs signing.
- [`../../internal/blstutil`](../../internal/blstutil/) — source of the DST constants (hex-encoded for the plugin API).
- [`../`](../) — the `Backend` interface and provider overview.
