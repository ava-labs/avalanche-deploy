# config/

> Defines the `Config` struct, loads YAML, and layers environment-variable overrides for every backend.

## What this is
This package is the single source of truth for runtime configuration. Both `serve` and `keytool` build a `config.Config` from it before anything else runs. It declares `BackendType` (the backend selector) and per-provider sub-structs, and resolves values with the precedence CLI flags > environment variables > YAML file.

## Contents
- `config.go` — `Config`, `BackendType` constants, the per-provider structs, `Defaults`, `Addr`, `Load`, and `applyEnv`.
- `config.example.yaml` — annotated reference config covering every backend and the gRPC address.

## How it works
`Load(path)` starts from `Defaults()` (`backend: memory`, `listen: 127.0.0.1`, `port: 50051`), strictly decodes the file if `path != ""` (`KnownFields` — unknown keys are errors; an empty or fully commented-out file is fine), then calls `applyEnv` to overlay env vars. CLI flags are applied afterward by callers in `main`, so they win. `applyEnv` maps an upper-cased, `_`-joined key onto each field (`BACKEND`, `PORT`, `AWS_REGION`, `AWS_KMS_KEY_ID`, `GCP_*`, `AZURE_*`, `VAULT_*`). `BackendType` values are `memory`, `aws-kms`, `gcp-kms`, `azure-kv`, `vault`, `aws-nitro`. `Addr()` returns `Listen:Port`. Provider structs (`AWSConfig`, `GCPConfig`, `AzureConfig`, `VaultConfig`, `AWSNitroConfig`) carry only their own fields, e.g. `AWS.EncryptedBLSKeyPath`, `Vault.MountPath` (default `bls`).

## Troubleshooting
- Env var ignored: `applyEnv` only sets a field when the value is non-empty, and `PORT` is silently dropped if `strconv.Atoi` fails. Check the exact name (e.g. `AWS_ENCRYPTED_BLS_KEY_PATH`, not `AWS_KEY_PATH`).
- Backend silently defaults to `memory`: no `backend:` in YAML and no `BACKEND`/`--backend`. `Defaults()` seeds `memory`.
- `parsing config file ...`: malformed YAML or an unknown/misspelled key (strict decoding); `Load` wraps the decoder error with the file path.

## Related
- [../main/](../main/) — applies CLI-flag overrides on top of `Load`.
- [../keytool/](../keytool/) — consumes the same per-provider structs.
- [../docs/architecture.md](../docs/architecture.md), plus per-backend guides: [aws-kms.md](../docs/aws-kms.md), [gcp-kms.md](../docs/gcp-kms.md), [azure-kv.md](../docs/azure-kv.md), [vault.md](../docs/vault.md), [aws-nitro.md](../docs/aws-nitro.md).
