# api/awsnitro/

> `Backend` implementation that runs all BLS signing inside an AWS Nitro Enclave — the host never sees the plaintext key.

## What this is
The `aws-nitro` backend, the strongest-isolation provider. The host signer launches the enclave, hands it temporary AWS credentials over vsock (the enclave has no IMDS access), and the enclave decrypts the BLS key via KMS and signs internally; only signatures and the public key cross the boundary. It is one of the `api.Backend` providers behind `signerserver/`, selected when `backend: aws-nitro`, and is Linux-only.

## Contents
- `awsnitro.go` (`//go:build linux`) — real backend: enclave lifecycle (`nitro-cli`), vsock dialing, init/sign requests.
- `awsnitro_stub.go` (`//go:build !linux`) — placeholder so the binary compiles on macOS etc.; every method returns an "only supported on Linux" error.

## How it works
On Linux, `New` checks `enclaveRunning(cid)`; if not, it runs `nitro-cli run-enclave` with `EIFPath`/`CPUCount`/`MemoryMiB`/`EnclaveCID`. If an enclave is already up and its signing port is open (`isEnclaveReady`), it reconnects and just fetches the public key — so restarting the signer does not disrupt a healthy enclave. Otherwise `buildInitMessage` pulls temporary creds from the AWS config chain and `sendInitWithRetry` sends an `enclaveproto.InitMessage` to vsock port 5001 (`VSockInitPort`), receiving the 48-byte key. `Sign`/`SignProofOfPossession` send `enclaveproto.Request{Type: RequestSign|RequestSignPoP}` to port 5000 (`VSockPort`); the DST split lives inside the enclave (request type selects it), and responses are validated to 96 bytes. `Close` runs `nitro-cli terminate-enclave`. On non-Linux the stub's `New` errors out immediately.

## Troubleshooting
- "aws-nitro backend is only supported on Linux" → you built/ran the stub; this backend requires Linux on an EC2 instance with Nitro Enclaves enabled.
- `nitro-cli run-enclave` fails → enclaves not enabled on the instance, `eif_path` missing, or `cpu_count`/`memory_mib` below minimums (≥2 vCPU, ≥512 MiB); also ensure the allocator service has reserved resources.
- "vsock dial" / timeouts on init → `enclave_cid` mismatch (must be ≥4) or the enclave hasn't opened its ports yet (init retries for 30s); confirm the EIF actually listens on 5000/5001.
- "enclave init error" from KMS → the enclave's KMS decrypt was denied; the key policy must permit the enclave's PCR0 attestation and the passed-in credentials must allow `kms:Decrypt`.
- Enclave seems healthy but signatures rejected on-chain → DST handling is inside the enclave image; rebuild/redeploy the EIF (host code only selects request type).
- Stale/zombie enclave after a crash → `nitro-cli describe-enclaves`; the backend reconnects to a matching CID, but a wrong-image enclave must be terminated manually.

## Related
- [`docs/aws-nitro.md`](../../docs/aws-nitro.md) — end-to-end setup (EC2, EIF build, KMS PCR policy).
- [`../../enclave`](../../enclave/) — the enclave-side program that decrypts and signs.
- [`../../internal/enclaveproto`](../../internal/enclaveproto/) — the vsock request/response protocol and ports.
- [`../`](../) — the `Backend` interface and provider overview.
