# End-to-end test (AWS)

A full end-to-end test of the `aws-kms` backend on **real AWS infrastructure**,
driven by the AWS CLI. It proves that an AvalancheGo node, configured to use the
remote signer, signs warp/ICM messages and proofs of possession correctly with a
key that lives only in AWS KMS.

## What it does

[`scripts/e2e-aws.sh`](../scripts/e2e-aws.sh) (orchestrator, runs locally / in CI):

1. **Provision** (AWS CLI): a KMS key, an IAM role + instance profile scoped to
   `kms:Encrypt`/`kms:Decrypt` on that key, an SSH key pair, a security group
   (SSH from your IP only), and an **EC2 instance** — the "node".
2. **Deploy**: ships this repo (`git archive HEAD`) to the instance and runs
   [`scripts/e2e/remote-setup.sh`](../scripts/e2e/remote-setup.sh), which builds
   the signer, runs `keytool generate` (encrypting the BLS key under KMS via the
   instance profile), starts the signer, then starts avalanchego with
   `--staking-rpc-signer-endpoint=127.0.0.1:50051`.
3. **Validate**: reads the node's BLS identity from `info.getNodeID` and runs the
   [`tests/e2e`](../tests/e2e) validator, which over gRPC:
   - confirms the signer's public key is a valid BLS key;
   - signs a message and verifies it with avalanchego's `bls.Verify` (the exact
     operation warp/ICM signing performs) — and confirms it is **not** a PoP;
   - signs + verifies a proof of possession with `bls.VerifyProofOfPossession`;
   - confirms the running node's `nodePOP.publicKey` equals the signer's key and
     its proof of possession verifies — i.e. the node really is using the signer.
4. **Teardown**: deletes every resource (EC2, SG, key pair, IAM role/profile) and
   schedules the KMS key for deletion. Runs via an `EXIT` trap, even on failure.

Everything created is tagged `e2e-remote-signer=<run-id>`.

## Prerequisites

- AWS credentials with permission to manage **KMS, EC2, and IAM** (e.g. `aws sso login` or env vars).
- AWS CLI v2, `jq`, `ssh`/`scp`, `git`.
- Outbound internet from the EC2 instance (Go toolchain, avalanchego release, Go modules).

## Run it

```bash
# uses your default AWS credentials/region
AWS_REGION=us-east-1 ./scripts/e2e-aws.sh
```

Tunables (env): `AWS_REGION`, `E2E_INSTANCE_TYPE` (default `t3.xlarge`),
`E2E_NETWORK_ID` (default `fuji`), `AVALANCHEGO_VERSION` (default `v1.14.0`,
must support `--staking-rpc-signer-endpoint`), `GO_VERSION`,
`E2E_KEEP=1` (skip teardown for debugging — **you** must then clean up).

> 💰 **Cost**: this launches a real EC2 instance and creates a KMS key. The script
> tears them down automatically (KMS keys have a mandatory ≥7-day deletion window,
> billed minimally until then). If the run is interrupted before the trap fires,
> delete leftovers by the `e2e-remote-signer` tag.

## CI

[`.github/workflows/e2e-aws.yml`](../.github/workflows/e2e-aws.yml) runs it on
**manual dispatch only** (it costs money). It authenticates to AWS via OIDC — set
the repo variable `E2E_AWS_ROLE_ARN` to a role the GitHub OIDC provider may assume.

## Why not full cross-chain ICM?

This validates warp signing at the signer + node-identity level, which is what the
signer is responsible for. Emitting a *real* cross-chain ICM message would require
standing up a subnet/L1 with ICM and a relayer — that exercises avalanchego/ICM far
more than the signer. It's a natural follow-on, not part of this harness.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `no working AWS credentials` | Not logged in / no env creds. Run `aws sts get-caller-identity` first. |
| Signer fails to start, `KMS decrypt: AccessDeniedException` | Instance-profile IAM propagation lag, or key policy. The script sleeps 12s; raise if needed. |
| `node API/getNodeID never came up` | avalanchego flags differ for your version, or the box is too small — check `/tmp/agonode.log`, bump `E2E_INSTANCE_TYPE`. |
| `Sign output does NOT verify` | DST regression in the signer — see [`internal/blstutil`](../internal/blstutil) and the `tests/` cross-check. |
| `go${GO_VERSION}...: 404` | That Go patch isn't published; set `GO_VERSION` to an available one. |
| Leftover resources | Filter by tag `e2e-remote-signer` in the EC2/KMS/IAM consoles and delete. |
