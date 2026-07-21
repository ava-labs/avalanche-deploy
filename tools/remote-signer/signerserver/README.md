# signerserver/

> The gRPC server that exposes a pluggable `api.Backend` as the AvalancheGo signer service.

## What this is
This package implements the `Signer` gRPC service defined in `spec/signer/signer.proto` (generated into `spec/pb/signer/`). It is the network boundary AvalancheGo talks to via `--staking-rpc-signer-endpoint`. The server is backend-agnostic: it holds an `api.Backend` and forwards every RPC to it, doing no cryptography itself.

## Contents
- `signerserver.go` — `Server` type, `New` constructor, the three RPC handlers, and `ListenAndServe`.
- `signerserver_test.go` — in-process tests over a real gRPC connection (uses `mockapi`).

## How it works
`New(b api.Backend, log)` returns a `*Server` embedding `pb.UnimplementedSignerServer`. It implements three RPCs that map 1:1 onto the backend: `PublicKey` → `backend.PublicKey` (returns the 48-byte key), `Sign` → `backend.Sign(req.Message)`, and `SignProofOfPossession` → `backend.SignProofOfPossession(req.Message)` (each returns a 96-byte signature). The warp-vs-PoP DST distinction lives entirely in the backend, not here. Any backend error is logged and returned as `status.Errorf(codes.Internal, ...)`. `ListenAndServe(ctx, addr, srv)` does `net.Listen("tcp", addr)`, registers the service with `grpc.NewServer()`, and blocks on `Serve`; a goroutine watches `ctx.Done()` and calls `GracefulStop`. There is no TLS or auth — it is meant to bind to loopback only.

## Troubleshooting
- `listen 127.0.0.1:50051: address already in use`: another signer (or AvalancheGo's built-in signer) holds the port; stop it or change `port`.
- AvalancheGo can't reach the signer: confirm `--staking-rpc-signer-endpoint` matches `cfg.Addr()` and that `listen` is not a non-routable bind (default loopback is correct for a co-located sidecar).
- RPC returns `Internal` errors: the failure is inside the backend (KMS perms, unreachable Vault, bad key blob). Check the server's JSON log line (`Sign failed`/`PublicKey failed`) and the backend's own docs in `docs/`.
- Signatures rejected by warp verifiers but RPC succeeds: this server doesn't apply the DST — see `../internal/blstutil/` (`DSTSign` must end in `RO_POP_`, not `RO_NUL_`).

## Related
- [../api/api.go](../api/api.go) — the `Backend` interface forwarded here.
- [../main/](../main/) — builds the backend and calls `ListenAndServe`.
- [../spec/signer/signer.proto](../spec/signer/signer.proto) — service definition.
- [../docs/architecture.md](../docs/architecture.md) — full request flow.
