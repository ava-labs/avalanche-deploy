# End-to-end tests

Full-stack tests that prove an AvalancheGo node, configured to use the remote
signer, signs warp/ICM messages and proofs of possession correctly — with the
private key held by the chosen backend (KMS, Vault, or Nitro enclave).

| Backend | Orchestrator | Host provisioning |
|---|---|---|
| `aws-kms` | [`scripts/e2e-aws.sh`](../scripts/e2e-aws.sh) | Optional (AWS CLI); reuse EC2 common |
| `gcp-kms` 🧪 | [`scripts/e2e-gcp.sh`](../scripts/e2e-gcp.sh) | Reuse a Linux VM with GCP credentials |
| `azure-kv` 🧪 | [`scripts/e2e-azure.sh`](../scripts/e2e-azure.sh) | Reuse a Linux VM with Azure credentials |
| `vault` | [`scripts/e2e-vault.sh`](../scripts/e2e-vault.sh) | Reuse a host with Vault + BLS plugin |
| `aws-nitro` | [`scripts/e2e-aws-nitro.sh`](../scripts/e2e-aws-nitro.sh) | Reuse a Nitro-enabled EC2 host |

All backends share [`scripts/e2e/remote-setup.sh`](../scripts/e2e/remote-setup.sh)
(except Nitro, which uses [`remote-setup-nitro.sh`](../scripts/e2e/remote-setup-nitro.sh))
and the same [`tests/e2e`](../tests/e2e) gRPC validator.

> ✅ **Validated**: `aws-kms` (EC2 reuse mode), `vault` (Ubuntu 24.04 VM,
> Vault + BLS plugin installed by `setup-vault-host.sh`; passed 2026-07-14), and
> `aws-nitro` (full-rebuild mode on a Nitro-enabled EC2 host — fresh key baked
> into a new EIF, attested KMS decrypt inside the enclave; passed 2026-07-14)
> have all completed this suite against real infrastructure with
> `ALL CHECKS PASSED`.
>
> **🧪 Experimental**: the `gcp-kms` and `azure-kv` orchestrators exist but have
> **never been run against real GCP/Azure infrastructure** (no test VM was
> available). Treat those backends as experimental until an E2E run passes here;
> expect first-run fixes.

## Quick reference — what you need before running

| Backend | Run from laptop | One-time host / cloud setup |
|---|---|---|
| `aws-kms` | AWS CLI, `jq`, `ssh` | KMS key + IAM on EC2 (or let script provision) — [aws-kms.md](aws-kms.md) |
| `aws-nitro` | same + reuse EC2 | Nitro EC2, KMS key + IAM `Decrypt`, `vsock-proxy` — [aws-nitro.md](aws-nitro.md) |
| `gcp-kms` | `ssh`, `jq` | GCE VM + Cloud KMS key + SA with `cryptoKeyEncrypterDecrypter` — [gcp-kms.md](gcp-kms.md) |
| `azure-kv` | `ssh`, `jq` | Azure VM + Key Vault RSA key + managed identity (`encrypt` + `decrypt`) — [azure-kv.md](azure-kv.md) |
| `vault` | `ssh`, `jq` | Vault server + BLS plugin on host — [`scripts/setup-vault-host.sh`](../scripts/setup-vault-host.sh) |

**Laptop CLIs** (`gcloud`, `az`, `vault`) are only needed to **provision** cloud resources — not to run the E2E orchestrators (those use `ssh`/`scp` only). Exception: `gcloud`/`az` if you create VMs/keys from your machine.

GCP, Azure, Vault, and Nitro use **reuse-host mode**: you provide `E2E_HOST` + `E2E_SSH_KEY`; the script ships the repo tarball to the host (macOS `scp` does not support `--exclude` — the scripts use `tar` internally).

---

# AWS KMS (`aws-kms`)

A full end-to-end test of the `aws-kms` backend on **real AWS infrastructure**,
driven by the AWS CLI.

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

See [Shared remote setup behavior](#shared-remote-setup-behavior) below.

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
| `GO_VERSION` | `1.25.12` | Go toolchain on the remote host |
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

---

# GCP Cloud KMS (`gcp-kms`)

Runs on a **reused GCE Linux VM** with GCP credentials (attached service account or
ADC). The VM needs `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the target
crypto key (`encrypt` is required because E2E runs `keytool generate`). See
[gcp-kms.md](gcp-kms.md) for key ring, key, service account, and VM setup.

**Prerequisites (one-time):**

1. GCP project with Cloud KMS API enabled
2. Key ring + symmetric key (e.g. `avalanche` / `bls-signer`)
3. GCE VM with a service account that has `cryptoKeyEncrypterDecrypter` on that key
4. SSH access to the VM (`E2E_HOST`, `E2E_SSH_KEY`)

```bash
E2E_HOST=10.0.0.5 E2E_SSH_KEY=~/.ssh/key.pem \
GCP_PROJECT=my-project GCP_LOCATION=us-central1 \
GCP_KEY_RING=avalanche GCP_KEY_NAME=bls-signer \
  ./scripts/e2e-gcp.sh
```

| Variable | Required | Notes |
|---|---|---|
| `E2E_HOST` | yes | VM IP or hostname |
| `E2E_SSH_KEY` | yes | SSH private key |
| `E2E_SSH_USER` | no | Default `ubuntu` |
| `GCP_PROJECT` | yes | |
| `GCP_LOCATION` | yes | e.g. `us-central1` |
| `GCP_KEY_RING` | yes | |
| `GCP_KEY_NAME` | yes | |

---

# Azure Key Vault (`azure-kv`)

Runs on a **reused Azure Linux VM** with Azure credentials (managed identity
recommended). The identity needs **`encrypt` and `decrypt`** on the Key Vault RSA
key (`encrypt` is required because E2E runs `keytool generate`). See
[azure-kv.md](azure-kv.md) for Key Vault, RSA key, managed identity, and VM setup.

**Prerequisites (one-time):**

1. Key Vault + RSA key (`bls-signer`, encrypt + decrypt ops)
2. Azure VM with user-assigned managed identity + Key Vault access policy
3. SSH access to the VM (`E2E_HOST`, `E2E_SSH_KEY`)

```bash
E2E_HOST=10.0.0.5 E2E_SSH_KEY=~/.ssh/key.pem \
AZURE_VAULT_URL=https://my-vault.vault.azure.net \
AZURE_KEY_NAME=bls-signer \
  ./scripts/e2e-azure.sh
```

| Variable | Required | Notes |
|---|---|---|
| `E2E_HOST` | yes | VM IP or hostname |
| `E2E_SSH_KEY` | yes | SSH private key |
| `AZURE_VAULT_URL` | yes | |
| `AZURE_KEY_NAME` | yes | RSA key name in the vault |

# HashiCorp Vault (`vault`)

Runs on a **reused Linux host** where Vault and the `vault-plugin-bls` are already
installed and registered. E2E can reuse an existing EC2 instance (same host as AWS
E2E). See [vault.md](vault.md) for production setup; for E2E use the automated
host script below.

### One-time host setup

On the Linux host (e.g. EC2), after shipping the repo:

```bash
# From your laptop — ship repo (macOS scp has no --exclude; use tar)
cd /path/to/avalanche-remote-signer
COPYFILE_DISABLE=1 tar -czf /tmp/repo.tgz --exclude=.git --exclude='*.enc' .
scp -i ~/.ssh/key.pem /tmp/repo.tgz ec2-user@HOST:/tmp/
ssh -i ~/.ssh/key.pem ec2-user@HOST \
  'mkdir -p ~/remote-signer && tar -xzf /tmp/repo.tgz -C ~/remote-signer'

# On the host (or via ssh one-liner)
export VAULT_ADDR=http://127.0.0.1:8200
bash ~/remote-signer/scripts/setup-vault-host.sh
```

[`scripts/setup-vault-host.sh`](../scripts/setup-vault-host.sh) installs Vault (if
needed), starts a dev server under `~/vault-e2e/` (not `~/.vault` — that path is
reserved for the Vault CLI token helper), builds the plugin, registers it,
enables `bls/`, and prints an E2E-scoped token.

If you already initialized Vault manually, ensure it is **unsealed** (`vault status`
→ `Sealed: false`) before running the script or E2E.

### Run E2E from your laptop

```bash
E2E_HOST=10.0.0.5 E2E_SSH_KEY=~/.ssh/key.pem E2E_SSH_USER=ec2-user \
VAULT_ADDR=http://127.0.0.1:8200 \
VAULT_TOKEN=s.... \
VAULT_KEY_NAME=validator \
VAULT_MOUNT_PATH=bls \
  ./scripts/e2e-vault.sh
```

`VAULT_ADDR` may be `http://127.0.0.1:8200` when Vault runs on the same host you
SSH into. No encrypted blob is written — `keytool generate --backend vault` stores
the key inside Vault.

| Variable | Required | Notes |
|---|---|---|
| `E2E_HOST` | yes | Host IP |
| `E2E_SSH_KEY` | yes | SSH private key |
| `VAULT_ADDR` | yes | Vault API URL reachable from the host |
| `VAULT_TOKEN` | yes | Token with `generate` + `sign` on `bls/keys/*` |
| `VAULT_KEY_NAME` | yes | Key name (created each E2E run) |
| `VAULT_MOUNT_PATH` | no | Default `bls` |

---

# AWS Nitro Enclave (`aws-nitro`)

Runs on a **reused Nitro-enabled EC2** host (Amazon Linux 2023, `nitro-cli`,
`docker`). Requires IAM `kms:Encrypt`/`kms:Decrypt`. The key policy must **not** have a
`kms:RecipientAttestation:*` condition — the enclave sends no attestation
document, so such a condition always denies. See [aws-nitro.md](aws-nitro.md).

```bash
export AWS_PROFILE=remoteE2E
AWS_REGION=us-east-2 \
E2E_KMS_KEY_ARN=arn:aws:kms:us-east-2:ACCOUNT:key/KEY-ID \
E2E_HOST=1.2.3.4 E2E_SSH_KEY=~/.ssh/key.pem E2E_SSH_USER=ec2-user \
  ./scripts/e2e-aws-nitro.sh
```

The script rebuilds the EIF with a fresh key each run (slow). Set `E2E_SKIP_EIF_REBUILD=1` only when reusing an EIF that already embeds the key under test. Rebuilding changes **PCR0**, which today is informational only — the KMS key policy is IAM-based, so no policy update is needed (see [aws-nitro.md](aws-nitro.md)).

| Variable | Notes |
|---|---|
| `E2E_EIF_PATH` | Use a pre-built EIF (default `~/remote-signer.eif` on host) |
| `E2E_SKIP_EIF_REBUILD` | Set to `1` to reuse an existing EIF (must match the generated key) |
| `E2E_ENCLAVE_CID` | Nitro enclave CID (default `16`) |

First-time Nitro setup (KMS key policy, EIF build) is manual per
[aws-nitro.md](aws-nitro.md); the E2E script automates a **repeatable test run**
once the host is prepared.

---

## Shared remote setup behavior

On the remote host, `remote-setup.sh` / `remote-setup-nitro.sh`:

- Installs build deps via `apt-get` (Ubuntu) or `dnf`/`yum` (Amazon Linux).
- Stops any process listening on ports **50051** (signer) and **9650** (node API)
  before starting — important on reused hosts where a prior run may have left
  stale processes bound to the old key.
- **Nitro only:** stops production `remote-signer` / `avalanchego` systemd units if
  active, terminates **all** running enclaves (not just a single CID), then rebuilds
  the EIF unless `E2E_SKIP_EIF_REBUILD=1`.
- Uses a fresh AvalancheGo data dir per run (`/tmp/agodata-<run-id>`).
- Verifies the signer's gRPC public key matches `keytool generate` output before
  starting avalanchego.
- Cleans up node/signer processes and the temp data dir when validation finishes.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `no working AWS credentials` | Not logged in / no env creds. Run `aws sts get-caller-identity` first. |
| `Permission denied` on `~/.aws/sso` | `~/.aws` owned by root (often from `sudo aws`). Fix ownership, then `aws sso login`. |
| `kms:CreateKey` denied by SCP | Set `E2E_KMS_KEY_ARN` to an existing key; ensure its key policy allows the EC2 instance role `kms:Encrypt`/`kms:Decrypt`. |
| `iam:CreateRole` denied by SCP | Ask admin for a pre-created instance profile; set `E2E_INSTANCE_PROFILE` to its name. |
| `ec2:RunInstances` denied by SCP | Use an existing EC2 host with the right instance profile; set `E2E_INSTANCE_ID` (or `E2E_HOST`), `E2E_SSH_KEY`, and `E2E_SSH_USER`. |
| GCP/Azure `AccessDenied` on remote host | VM identity lacks KMS/Key Vault permissions — attach the right service account or managed identity. |
| Vault `permission denied` | Wrong token, plugin not registered, or `VAULT_MOUNT_PATH` / `VAULT_KEY_NAME` mismatch. Token needs `generate` + `sign` paths — use token from `setup-vault-host.sh`. |
| Vault `permission denied` on `/var/lib/vault/data` | RPM installs Vault as user `vault`; E2E uses `~/vault-e2e/` via `setup-vault-host.sh` instead. |
| Vault `failed to get token helper: ~/.vault is a directory` | Do not use `~/.vault` as server data dir — use `~/vault-e2e` (see setup script). |
| Vault sealed (`503`) | Run `vault operator unseal` with key from `/tmp/vault-init.txt`. |
| `lstat .../vault-plugin-bls: no such file` | Build plugin: `cd vault-plugin && CGO_ENABLED=1 go build -o ~/vault-e2e/plugins/vault-plugin-bls .` |
| Nitro signer times out on vsock | EIF not built, IAM denies `kms:Decrypt` (or the key policy has an attestation condition the enclave can't satisfy), or `vsock-proxy` not running — see [aws-nitro.md](aws-nitro.md). |
| Nitro `run-enclave: exit status 39` | Stale enclave or production `remote-signer` systemd unit still running — E2E stops those services and terminates all enclaves before each run. |
| Nitro pubkey ≠ keytool output | Stale enclave with an old key — terminate with `nitro-cli terminate-enclave --enclave-id <id>` (`nitro-cli describe-enclaves` for the id). |
| SSH connection refused / timeout | Wrong `E2E_SSH_USER` (`ubuntu` vs `ec2-user`), wrong `.pem`, or security group blocks your IP on a reused host. |
| Signer fails to start, `KMS decrypt: AccessDeniedException` | Instance-profile IAM propagation lag, or key policy. The script sleeps 12s when creating IAM; raise if needed. |
| `apt-get: command not found` on remote host | Host is Amazon Linux — `remote-setup.sh` uses `dnf` automatically. |
| keytool pubkey ≠ node/signer pubkey | Stale signer or node on a reused host — scripts stop ports 50051/9650 and verify the signer key before continuing. |
| `node API/getNodeID never came up` | avalanchego flags differ for your version, or the box is too small — check `/tmp/agonode.log`, bump `E2E_INSTANCE_TYPE`. |
| `Sign output does NOT verify` | DST regression in the signer — see [`internal/blstutil`](../internal/blstutil) and the `tests/` cross-check. |
| `ParameterNotFound` on Ubuntu AMI lookup | That region may lack the gp3 SSM path; the script falls back to gp2 automatically. Set `E2E_AMI_ID` to override. |
| `tar: Ignoring unknown extended header keyword LIBARCHIVE.xattr` | Harmless macOS xattr warnings on the remote host; the script sets `COPYFILE_DISABLE=1` when packing. |
| Leftover AWS resources | Filter by tag `e2e-remote-signer` in the EC2/KMS/IAM consoles and delete (provisioned resources only). |
