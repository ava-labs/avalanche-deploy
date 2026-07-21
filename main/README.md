# main/

> Cobra CLI entry point that selects a KMS backend and either serves gRPC or manages keys.

## What this is
This is the executable `main` package for `avalanche-remote-signer`. It wires command-line flags, environment variables, and the YAML config file into a single `config.Config`, picks a signing backend, and dispatches to either the gRPC signing server (`serve`) or the offline key-management commands (`keytool`). It is the only place that imports every concrete backend, so adding a provider means adding one `case` to `buildBackend`.

## Contents
- `main.go` — `rootCmd`, the `serve` and `keytool generate`/`keytool migrate` subcommands, flag wiring, and the `buildBackend` factory.

## How it works
`main()` builds `rootCmd(log)` and calls `Execute()`. `serveCmd` runs `config.Load(configFile)`, applies flag overrides (`--backend`, `--port`, `--listen`, `--aws-endpoint-url`), calls `buildBackend(cfg, log)`, then `signerserver.New(b, log)` and `signerserver.ListenAndServe(ctx, cfg.Addr(), srv)`. The context is from `signal.NotifyContext` on SIGINT/SIGTERM, so Ctrl-C triggers `GracefulStop` and `b.Close()`. `buildBackend` switches on `cfg.Backend` (`config.BackendType`) and returns the matching `api.Backend`: `memory`→`mockapi.New()`, `aws-kms`→`awskms.New`, `gcp-kms`→`gcpkms.New`, `azure-kv`→`azurekv.New`, `vault`→`vault.New`, `aws-nitro`→`awsnitro.New`. The `keytool` subcommands share `commonKMSFlags`/`resolveKMSConfig` and call into the `keytool` package rather than `buildBackend`.

## Troubleshooting
- `unknown backend "..."`: `cfg.Backend` is unset or misspelled. The error message lists `memory, aws-kms, gcp-kms, azure-kv`; `vault` and `aws-nitro` are also valid in `buildBackend`. Set `backend:` in YAML, `BACKEND=`, or `--backend`.
- Started with `--backend memory` in prod: the log emits `using in-memory backend — DO NOT use in production` and a throwaway key is generated each start. See `../mockapi/`.
- `--port`/`--listen` ignored: only non-zero/non-empty flag values override config (see the `if port != 0` / `if listen != ""` guards). Use env vars or the YAML file otherwise.
- Server exits immediately with `listen ...: address already in use`: another process holds `cfg.Addr()` (default `127.0.0.1:50051`).

## Related
- [../signerserver/](../signerserver/) — the gRPC server this command starts.
- [../config/](../config/) — `Config`, `BackendType`, and precedence rules.
- [../keytool/](../keytool/) — implementation behind `keytool generate`/`migrate`.
- [../docs/architecture.md](../docs/architecture.md) — end-to-end request flow.
