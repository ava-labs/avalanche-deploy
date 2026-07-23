# remote_signer (Ansible role)

Runs [avalanche-remote-signer](https://github.com/ava-labs/avalanche-remote-signer)
as a container on the validator host so the BLS key lives behind a KMS/Vault
backend instead of as plaintext on disk. It is the VM/bare-metal analog of the
Kubernetes sidecar in `kubernetes/helm/avalanche-validator`.

**Off by default.** With `remote_signer_enabled` unset, `deploy-nodes.yml`
skips this role and the avalanchego config is unchanged.

## How it works

The role runs the published signer image under a systemd unit
(`remote-signer.service`) with `docker run --network host`, so it binds the
host's `127.0.0.1:50051`. The native avalanchego reaches it over loopback, and
cloud-KMS backends read the instance's IMDS credentials — the same posture as
the k8s sidecar (loopback only, no TLS, key never on the node). When enabled on
a validator, the `avalanchego` role automatically adds
`--staking-rpc-signer-endpoint=127.0.0.1:50051`.

`aws-nitro` is **not** supported here — enclaves need host devices; use a
dedicated Nitro host per the signer repo's `docs/aws-nitro.md`.

## Enable it

Every validator needs its **own** BLS key — the blob determines the identity,
and a shared key is an invalid validator set. The role enforces this: with
more than one validator in the inventory it refuses a single
`remote_signer_encrypted_bls_key_src` and requires per-host blobs.

Set these (group_vars, or `-e`), then run `playbooks/l1/deploy-nodes.yml`:

```yaml
remote_signer_enabled: true
remote_signer_backend: aws-kms          # aws-kms | gcp-kms | azure-kv | vault
remote_signer_aws:
  region: us-east-1
# Per-host KMS key ARNs, straight from terraform:
#   terraform output -json remote_signer_kms_key_arns
remote_signer_kms_key_arns:
  validator-1: arn:aws:kms:us-east-1:ACCOUNT:key/KEY-1
  validator-2: arn:aws:kms:us-east-1:ACCOUNT:key/KEY-2
# Directory (on the control node) with one blob per validator, named
# <inventory_hostname>.key.enc:
remote_signer_encrypted_bls_key_dir: ./blobs
# Single-validator setups may instead use remote_signer_encrypted_bls_key_src
# and remote_signer_aws.kms_key_id.
```

Generate the blobs first with the signer's `keytool generate`, one per
validator against that validator's KMS key, and register each printed public
key on-chain:

```bash
mkdir -p blobs
terraform output -json remote_signer_kms_key_arns | jq -r 'to_entries[] | "\(.key) \(.value)"' |
while read host arn; do
  avalanche-remote-signer keytool generate --backend aws-kms \
    --aws-region us-east-1 --aws-kms-key-id "$arn" --output "blobs/${host}.key.enc"
done
```

On AWS, the per-validator KMS keys + instance-role permission are provisioned
by the terraform variable `enable_remote_signer_kms` (see
`terraform/l1/aws/remote-signer.tf`).

> **vault backend:** the key lives in Vault under `remote_signer_vault.key_name`
> — a single global name would likewise share one key across validators. Use a
> per-host override (host_vars) for `key_name` in multi-validator setups.

## Verify

```bash
systemctl status remote-signer
journalctl -u remote-signer          # logs the served public key at startup
```

Confirm the node's `info.getNodeID` `nodePOP.publicKey` matches — that proves
avalanchego is signing through the sidecar. The signer is on the signing path;
monitor it (a node can be "up but not signing") — see the signer repo's
`docs/monitoring.md`.

## Variables

See `defaults/main.yml`. Key ones: `remote_signer_backend`,
`remote_signer_image` / `remote_signer_image_digest` (pinned to v0.1.0),
`remote_signer_encrypted_bls_key_dir` / `remote_signer_encrypted_bls_key_src`,
`remote_signer_kms_key_arns`, and the per-backend
`remote_signer_{aws,gcp,azure,vault}` blocks.
