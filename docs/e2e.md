# End-to-end test (AWS)

A full end-to-end test of the `aws-kms` backend on **real AWS infrastructure**,
driven by the AWS CLI. It proves that an AvalancheGo node, configured to use the
remote signer, signs warp/ICM messages and proofs of possession correctly with a
key that lives only in AWS KMS.

## What it does

[`scripts/e2e-aws.sh`](../scripts/e2e-aws.sh) (orchestrator, runs locally / in CI):

1. **Provision** (AWS CLI): a KMS key (created by the script, or an existing one
   via `E2E_KMS_KEY_ARN`), an IAM role + instance profile (created by the script,
   or an existing profile via `E2E_INSTANCE_PROFILE`) scoped to `kms:Encrypt`/
   `kms:Decrypt` on that key, an SSH key pair, a security group (SSH from your IP
   only), and an **EC2 instance** — the "node". When reusing an existing EC2 host
   (`E2E_HOST` / `E2E_INSTANCE_ID`), only SSH access is needed; the instance must
   already have the right instance profile attached.
2. **Deploy**: ships this repo's working tree to the instance and runs
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
4. **Teardown**: deletes every resource the script created (EC2, SG, key pair,
   IAM role/profile when it created them) and schedules the KMS key for deletion
   when the script created it. Reused resources (`E2E_KMS_KEY_ARN`,
   `E2E_INSTANCE_PROFILE`, `E2E_HOST` / `E2E_INSTANCE_ID`) are left in place.
   Runs via an `EXIT` trap, even on failure.

Resources the script creates are tagged `e2e-remote-signer=<run-id>` for auditing.

### Remote setup behavior

On the EC2 host, `remote-setup.sh`:

- Installs build deps via `apt-get` (Ubuntu) or `dnf`/`yum` (Amazon Linux).
- Stops any process listening on ports **50051** (signer) and **9650** (node API)
  before starting — important on reused hosts where a prior run may have left
  stale processes bound to the old key.
- Uses a fresh AvalancheGo data dir per run (`/tmp/agodata-<run-id>`).
- Verifies the signer's gRPC public key matches `keytool generate` output before
  starting avalanchego.
- Cleans up node/signer processes and the temp data dir when validation finishes.

## Run modes

| Mode | When to use | Required env vars |
|---|---|---|
| **Full provision** | Account/role can create KMS, IAM, and EC2 | (none — uses defaults) |
| **Reuse KMS + IAM** | Org SCP denies `kms:CreateKey` / `iam:CreateRole` but allows `ec2:RunInstances` | `E2E_KMS_KEY_ARN`, `E2E_INSTANCE_PROFILE` |
| **Reuse existing EC2** | Org SCP also denies `ec2:RunInstances` | `E2E_KMS_KEY_ARN`, `E2E_HOST` or `E2E_INSTANCE_ID`, `E2E_SSH_KEY` |

`E2E_INSTANCE_PROFILE` is only needed when the script **launches** a new EC2
instance. When using `E2E_HOST` / `E2E_INSTANCE_ID`, the instance must already
have an IAM instance profile with `kms:Encrypt` / `kms:Decrypt` on the KMS key,
and the key policy must allow that role.

## Prerequisites

**Always:**

- AWS credentials (e.g. `aws sso login` then `export AWS_PROFILE=...`, or env vars).
  Run `aws sts get-caller-identity` before starting.
- AWS CLI v2, `jq`, `ssh`/`scp`, `git`.
- Outbound internet from the EC2 instance (Go toolchain, avalanchego release, Go modules).

**Full provision mode** additionally needs permission to create and delete KMS
keys, IAM roles/instance profiles, EC2 instances, security groups, and key pairs.

**Reuse modes** need only:

- `kms:DescribeKey` plus `kms:Encrypt` / `kms:Decrypt` on the target key (via your
  SSO role for local runs; via the EC2 instance profile on the host).
- For `E2E_INSTANCE_ID`: `ec2:DescribeInstances`.
- SSH access to the existing host (`E2E_SSH_KEY`).

## Run it

```bash
# full provision (uses your default AWS credentials/region)
AWS_REGION=us-east-1 ./scripts/e2e-aws.sh

# reuse existing KMS key + IAM instance profile (SCP blocks CreateKey/CreateRole)
export AWS_PROFILE=my-sso-profile
AWS_REGION=us-east-2 \
E2E_KMS_KEY_ARN=arn:aws:kms:us-east-2:123456789012:key/abc-def \
E2E_INSTANCE_PROFILE=bls-validator \
  ./scripts/e2e-aws.sh

# reuse an existing EC2 host (SCP also blocks RunInstances)
export AWS_PROFILE=my-sso-profile
AWS_REGION=us-east-2 \
E2E_KMS_KEY_ARN=arn:aws:kms:us-east-2:123456789012:key/abc-def \
E2E_HOST=<validator-host> \
E2E_SSH_KEY=~/.ssh/bls-validator.pem \
E2E_SSH_USER=ec2-user \
  ./scripts/e2e-aws.sh
```

Tunables (env):

| Variable | Default | Notes |
|---|---|---|
| `AWS_REGION` | `us-east-1` | Region for KMS and (when launched) EC2 |
| `AWS_PROFILE` | (none) | SSO or named profile; export before running |
| `E2E_KMS_KEY_ARN` | (create key) | Use a pre-existing KMS key |
| `E2E_INSTANCE_PROFILE` | (create IAM) | Pre-existing profile when launching EC2 |
| `E2E_HOST` / `E2E_INSTANCE_ID` | (launch EC2) | Reuse an existing host; requires `E2E_SSH_KEY` |
| `E2E_SSH_KEY` | (script key pair) | Path to `.pem` for reused host |
| `E2E_SSH_USER` | `ubuntu` | Use `ec2-user` for Amazon Linux AMIs |
| `E2E_INSTANCE_TYPE` | `t3.xlarge` | Only when launching EC2 |
| `E2E_AMI_ID` | Ubuntu 22.04 via SSM | Override AMI when launching EC2 |
| `E2E_NETWORK_ID` | `fuji` | Avalanche network ID |
| `AVALANCHEGO_VERSION` | `v1.14.0` | Must support `--staking-rpc-signer-endpoint` |
| `GO_VERSION` | `1.25.8` | Go toolchain on the remote host |
| `E2E_RUN_ID` | auto-generated | Correlates tags, temp dirs, and logs |
| `E2E_KEEP` | `0` | Set to `1` to skip teardown (you clean up) |

> 💰 **Cost**: full provision and reuse-KMS modes launch a real EC2 instance for
> the duration of the run. Reuse-EC2 mode (`E2E_HOST`) uses an existing instance —
> no new instance-hour charges from this script, though the host must already be
> running. Script-created KMS keys are scheduled for deletion on teardown (≥7-day
> window, billed minimally until then); reused keys, instance profiles, and EC2
> hosts are left in place. If a run is interrupted before the trap fires, delete
> leftovers by the `e2e-remote-signer` tag (provisioned resources only).

## Reusing KMS + IAM (org SCP restrictions)

If your account denies `kms:CreateKey` or `iam:CreateRole`, ask an admin to
provision long-lived E2E resources once:

1. **KMS key** in your target region with `ENCRYPT_DECRYPT` usage.
2. **IAM role** trusted by `ec2.amazonaws.com` with inline policy allowing
   `kms:Encrypt` and `kms:Decrypt` on that key ARN.
3. **Instance profile** attaching that role (e.g. `bls-validator`).

The EC2 role also needs `kms:Encrypt`/`kms:Decrypt` allowed by the **KMS key
policy** (either via account-root delegation + IAM, or an explicit principal on
the key). SSO role ARNs in key policies may use the path
`aws-reserved/sso.amazonaws.com/<ROLE_NAME>` (no region segment).

Then run with `E2E_KMS_KEY_ARN` and `E2E_INSTANCE_PROFILE` set, or point at an
existing EC2 host that already has that profile attached.

## CI

[`.github/workflows/e2e-aws.yml`](../.github/workflows/e2e-aws.yml) runs it on
**manual dispatch only** (it costs money). It authenticates to AWS via OIDC — set
the repo variable `E2E_AWS_ROLE_ARN` to a role the GitHub OIDC provider may assume.

The workflow uses **full provision mode** (no reuse env vars). The OIDC role must
be able to create KMS keys, IAM roles, and EC2 instances — org SCPs that deny
those actions will block CI even when local reuse mode works. Reuse env vars are
not wired into the workflow today; add workflow inputs if your account needs them.

## Why not full cross-chain ICM?

This validates warp signing at the signer + node-identity level, which is what the
signer is responsible for. Emitting a *real* cross-chain ICM message would require
standing up a subnet/L1 with ICM and a relayer — that exercises avalanchego/ICM far
more than the signer. It's a natural follow-on, not part of this harness.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `no working AWS credentials` | Not logged in / no env creds. Run `aws sts get-caller-identity` first. |
| `Permission denied` on `~/.aws/sso` | `~/.aws` owned by root (often from `sudo aws`). Fix ownership, then `aws sso login`. |
| `kms:CreateKey` denied by SCP | Set `E2E_KMS_KEY_ARN` to an existing key; ensure its key policy allows the EC2 instance role `kms:Encrypt`/`kms:Decrypt`. |
| `iam:CreateRole` denied by SCP | Ask admin for a pre-created instance profile; set `E2E_INSTANCE_PROFILE` to its name. |
| `ec2:RunInstances` denied by SCP | Use an existing EC2 host with the right instance profile; set `E2E_INSTANCE_ID` (or `E2E_HOST`), `E2E_SSH_KEY`, and `E2E_SSH_USER`. |
| SSH connection refused / timeout | Wrong `E2E_SSH_USER` (`ubuntu` vs `ec2-user`), wrong `.pem`, or security group blocks your IP on a reused host. |
| Signer fails to start, `KMS decrypt: AccessDeniedException` | Instance-profile IAM propagation lag, or key policy. The script sleeps 12s when creating IAM; raise if needed. |
| `apt-get: command not found` on remote host | Host is Amazon Linux — `remote-setup.sh` uses `dnf` automatically. |
| keytool pubkey ≠ node/signer pubkey | Stale signer or node on a reused EC2 host — `remote-setup.sh` stops ports 50051/9650 and verifies the signer key before continuing. Pull latest script if you still see this. |
| `node API/getNodeID never came up` | avalanchego flags differ for your version, or the box is too small — check `/tmp/agonode.log`, bump `E2E_INSTANCE_TYPE`. |
| `Sign output does NOT verify` | DST regression in the signer — see [`internal/blstutil`](../internal/blstutil) and the `tests/` cross-check. |
| `ParameterNotFound` on Ubuntu AMI lookup | That region may lack the gp3 SSM path; the script falls back to gp2 automatically. Set `E2E_AMI_ID` to override. |
| `tar: Ignoring unknown extended header keyword LIBARCHIVE.xattr` | Harmless macOS xattr warnings on the remote host; the script sets `COPYFILE_DISABLE=1` when packing. |
| Leftover resources | Filter by tag `e2e-remote-signer` in the EC2/KMS/IAM consoles and delete (provisioned resources only). |
