# Remote signer sidecar (optional)

The `avalanche-validator` chart can run the
[avalanche-remote-signer](https://github.com/ava-labs/avalanche-remote-signer)
as a sidecar so the validator's **BLS key is never held by avalanchego** and
never sits in plaintext on the node. It is **off by default** — with
`remote_signer.enabled=false` (the default) the pod is byte-for-byte identical
to a stock validator.

## How it works

When enabled, a `remote-signer` container runs alongside `avalanchego` in the
same pod. Because containers in a pod share a network namespace, the signer
listens on `127.0.0.1:50051` and the node is started with
`--staking-rpc-signer-endpoint=127.0.0.1:50051`. Signing requests never leave
the pod, and the loopback-only default needs no TLS.

```
┌──────────────── validator pod ────────────────┐
│  avalanchego ──gRPC 127.0.0.1:50051──▶ remote- │
│  (no BLS key)                          signer  │──▶ backend (KMS / Vault / …)
└────────────────────────────────────────────────┘
```

## Enable it

1. **Write the signer config** (`remote-signer-config.yaml`). Backend block +
   `listen: 127.0.0.1` + `port: 50051`. Example (AWS KMS; see the signer repo's
   [deployment guide](https://github.com/ava-labs/avalanche-remote-signer/blob/main/docs/deployment.md)
   for every backend):

   ```yaml
   backend: aws-kms
   listen:  127.0.0.1
   port:    50051
   aws:
     region:                 us-east-1
     kms_key_id:             arn:aws:kms:us-east-1:ACCOUNT:key/KEY-ID
     encrypted_bls_key_path: /etc/avalanche/remote-signer/bls.key.enc
   ```

2. **Create the Secret** the chart mounts at `/etc/avalanche/remote-signer`
   (default name `<release>-remote-signer`, key `config.yaml`):

   ```bash
   kubectl create secret generic l1-validators-remote-signer \
     --from-file=config.yaml=./remote-signer-config.yaml \
     --from-file=bls.key.enc=./bls.key.enc     # if the backend reads a blob
   ```

   > Generate the encrypted key blob first with the signer's `keytool generate`
   > and register the printed public key on-chain. For cloud-KMS backends,
   > prefer **workload identity / IRSA** on the pod service account over static
   > credentials in the Secret.

3. **Enable in values:**

   ```yaml
   remote_signer:
     enabled: true
     # image is digest-pinned in values.yaml (v0.1.0); override to upgrade
   ```

   ```bash
   helm upgrade --install l1-validators ./helm/avalanche-validator \
     --set remote_signer.enabled=true
   ```

## Verify

After rollout, confirm the node is signing through the sidecar (not a local
key) and that the served identity matches your on-chain registration:

```bash
kubectl logs <pod> -c remote-signer   # logs its public key at startup
kubectl exec <pod> -c avalanchego -- \
  wget -qO- --post-data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
  --header 'content-type: application/json' http://127.0.0.1:9650/ext/info
```

The signer is on the validator's signing path — monitor it as such (a node can
be "up but not signing"): see the signer repo's
[monitoring guide](https://github.com/ava-labs/avalanche-remote-signer/blob/main/docs/monitoring.md).

## Notes & limitations

- **Backends that fit a pod:** `aws-kms`, `gcp-kms`, `azure-kv`, `vault`. The
  `aws-nitro` backend needs host-level Nitro Enclave devices and does **not**
  run as an ordinary sidecar — use a host/systemd deployment for that.
- The image is pinned by **digest** in `values.yaml` (immutable) — bump both
  the digest and the comment to upgrade.
