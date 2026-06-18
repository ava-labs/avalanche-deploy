# internal/enclaveproto/

> Wire protocol types for the vsock channel between the host signer and an AWS Nitro Enclave.

## What this is
Defines the length-prefixed JSON messages exchanged over vsock between the host process and the BLS-signing enclave VM. It is a shared leaf package: `api/awsnitro` imports it as the host (client) side and `enclave/` imports it as the enclave (server) side. It contains only types and constants — no I/O logic.

## Contents
- `protocol.go` — `RequestType` values, `Request`/`Response`, `InitMessage`/`InitResponse`, and vsock port/size constants.

## How it works
Two vsock ports:
- **`VSockInitPort` (5001)** — one-time handshake. The host sends an `InitMessage` carrying temporary AWS credentials (the enclave has no IMDS access); the enclave replies with `InitResponse` containing the hex public key.
- **`VSockPort` (5000)** — per-operation `Request` → `Response`. `Request.Type` is one of `RequestSign` (warp/ICM, signs with `DSTSign`), `RequestSignPoP` (signs with `DSTPoP`), or `RequestPublicKey`. `Response` returns hex-encoded `Result` (96-byte signature or 48-byte key) or a non-empty `Error`.

`MaxMessageSize` caps any framed message at 1 MB. Credentials cross the boundary, but the **plaintext BLS key never leaves the enclave** — that is the security win over the plain cloud-KMS backends.

## Troubleshooting
- Enclave rejects/cannot sign before any request works → the `InitMessage` on port 5001 was never sent or carried bad/expired credentials; the enclave can't reach KMS to decrypt the key. Send init first, with valid short-lived creds.
- `RequestSign` signatures rejected by the network while PoP works → wrong DST mapping in `enclave/`; `RequestSign` must use `blstutil.DSTSign`, `RequestSignPoP` must use `DSTPoP`.
- Truncated/oversized message errors → frame exceeds `MaxMessageSize`, or host and enclave disagree on the length-prefix framing; both sides must use these constants.
- Host/enclave version skew (unknown `RequestType`, JSON field mismatch) → rebuild both sides against the same revision of this package.

## Related
- [`../../api/awsnitro/`](../../api/awsnitro/) — host-side client that issues these requests.
- [`../../enclave/`](../../enclave/) — enclave-side server that handles them.
- [`../blstutil/`](../blstutil/) — DSTs the enclave applies per request type.
- [`../../docs/aws-nitro.md`](../../docs/aws-nitro.md) — Nitro Enclave deployment guide.
