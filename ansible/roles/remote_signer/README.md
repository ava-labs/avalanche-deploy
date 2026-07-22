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

Set these (group_vars, or `-e`), then run `playbooks/l1/deploy-nodes.yml`:

```yaml
remote_signer_enabled: true
remote_signer_backend: aws-kms          # aws-kms | gcp-kms | azure-kv | vault
remote_signer_aws:
  region: us-east-1
  kms_key_id: arn:aws:kms:us-east-1:ACCOUNT:key/KEY-ID   # terraform output remote_signer_kms_key_arn
# Path (on the control node) to the KMS-encrypted blob from `keytool generate`.
remote_signer_encrypted_bls_key_src: ./bls.key.enc
```

Generate the blob first with the signer's `keytool generate` (against the same
KMS key), and register the printed public key on-chain. On AWS, the KMS key +
instance-role permission can be provisioned by the terraform variable
`enable_remote_signer_kms` (see `terraform/l1/aws/remote-signer.tf`), which
requires `enable_staking_key_backup = true`.

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
`remote_signer_encrypted_bls_key_src`, and the per-backend
`remote_signer_{aws,gcp,azure,vault}` blocks.
