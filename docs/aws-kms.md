# AWS KMS Backend

This guide covers setting up the `aws-kms` backend end-to-end: creating the KMS key, configuring IAM permissions, generating or migrating your BLS key, and running the signer on EC2 or ECS.

---

## How it works

The BLS private key (32 bytes) is encrypted using AWS KMS symmetric encryption and stored as a local ciphertext blob. At startup, the signer calls `kms:Decrypt` to recover the plaintext key into memory. Signing happens in-process; the KMS key is never used for signing operations directly.

```
startup:  blob on disk ──kms:Decrypt──▶ BLS key in memory
runtime:  AvalancheGo ──gRPC──▶ signer ──blst──▶ signature (no KMS call)
shutdown: BLS key zeroed from memory
```

---

## Step 1 — Create a KMS key

In the AWS Console or via CLI:

```bash
aws kms create-key \
  --description "avalanche-remote-signer BLS key encryption" \
  --key-usage ENCRYPT_DECRYPT \
  --key-spec SYMMETRIC_DEFAULT \
  --region us-east-1
```

Note the key ARN from the output, e.g.:
```
arn:aws:kms:us-east-1:123456789012:key/abc12345-1234-1234-1234-abcdef123456
```

Optionally create an alias:

```bash
aws kms create-alias \
  --alias-name alias/avalanche-bls-signer \
  --target-key-id abc12345-1234-1234-1234-abcdef123456
```

> **Org SCP restrictions**: some enterprise accounts deny `kms:CreateKey` via
> service control policy. Ask an admin to provision a key for you, or use an
> existing key ARN. For automated testing when create permissions are blocked,
> see **[docs/e2e.md](e2e.md)** (reuse mode with `E2E_KMS_KEY_ARN`).

---

## Step 2 — Configure IAM permissions

Attach this policy to the IAM role used by your EC2 instance profile or ECS task role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowBLSKeyOperations",
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt"
      ],
      "Resource": "arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID"
    }
  ]
}
```

Both `kms:Encrypt` and `kms:Decrypt` are required:
- `kms:Encrypt` — used by `keytool generate` and `keytool migrate` to encrypt the BLS key blob
- `kms:Decrypt` — used by the signer at boot to decrypt the blob into memory

> **Advanced**: operators running large multi-validator deployments sometimes use a separate "key setup" IAM role with `kms:Encrypt` for initial key generation, and a separate runtime role with only `kms:Decrypt` for the signer process. This is optional for most operators.

### KMS key policy

IAM policies on the EC2/ECS role are not enough on their own — the **KMS key
policy** must also allow the principal to use the key. Common patterns:

1. **Account-root delegation** — key policy grants the account root full access;
   IAM policies on roles then scope `kms:Encrypt` / `kms:Decrypt` to specific
   principals.
2. **Explicit principal** — add the EC2 instance role ARN directly to the key
   policy (useful when IAM delegation is restricted).

For SSO / IAM Identity Center roles used during local development, the principal
ARN may look like:

```
arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/us-east-2/AWSReservedSSO_MyRole_abc123
```

or (without a region segment):

```
arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/MyRole
```

Check `aws sts get-caller-identity` and the IAM console for the exact ARN when
updating the key policy.

---

## Step 3 — Generate or migrate your BLS key

### New validator — generate a fresh key

```bash
./avalanche-remote-signer keytool generate \
  --backend aws-kms \
  --aws-region us-east-1 \
  --aws-kms-key-id arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID \
  --output /etc/avalanche/bls.key.enc
```

The command prints the derived BLS public key in hex. Register this on-chain when adding your validator.

### Existing validator — migrate signer.key

```bash
./avalanche-remote-signer keytool migrate \
  --backend aws-kms \
  --aws-region us-east-1 \
  --aws-kms-key-id arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID \
  --input ~/.avalanchego/staking/signer.key \
  --output /etc/avalanche/bls.key.enc
```

**Before adding `--delete-input`**: compare the printed public key to your registered on-chain key using `avalanche-cli node list`. Only add `--delete-input` once you have confirmed they match.

---

## Step 4 — Create a config file

`/etc/avalanche/config.yaml`:

```yaml
backend: aws-kms
listen:  127.0.0.1
port:    50051

aws:
  region:                 us-east-1
  kms_key_id:             arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID
  encrypted_bls_key_path: /etc/avalanche/bls.key.enc
```

---

## Step 5 — Run the signer

```bash
CGO_ENABLED=1 ./avalanche-remote-signer serve --config-file /etc/avalanche/config.yaml
```

Then start AvalancheGo with:

```bash
avalanchego \
  --staking-rpc-signer-endpoint=127.0.0.1:50051 \
  [your other flags]
```

---

## Systemd unit (recommended)

`/etc/systemd/system/avalanche-remote-signer.service`:

```ini
[Unit]
Description=Avalanche Remote Signer
After=network.target
Before=avalanchego.service

[Service]
Type=simple
User=avalanche
Environment=CGO_ENABLED=1
ExecStart=/usr/local/bin/avalanche-remote-signer serve --config-file /etc/avalanche/config.yaml
Restart=on-failure
RestartSec=5s

# Harden the process
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/etc/avalanche

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable avalanche-remote-signer
sudo systemctl start avalanche-remote-signer
sudo systemctl status avalanche-remote-signer
```

---

## Credentials

The signer uses the standard AWS credential chain in order:

1. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
2. `~/.aws/credentials` file
3. **EC2 instance profile** (recommended for production)
4. ECS task role
5. AWS SSO / IAM Identity Center

On EC2, attach an instance profile with the IAM policy from Step 2 — no credentials files or environment variables needed.

### AWS SSO (local development)

For IAM Identity Center / SSO:

```bash
aws configure sso
aws sso login --profile my-profile
export AWS_PROFILE=my-profile
aws sts get-caller-identity   # verify before running keytool or tests
```

- Export `AWS_PROFILE` in every shell session (or add it to your shell profile).
- Do **not** run `aws` with `sudo` — it can create `~/.aws` files owned by root
  and break SSO cache access (`Permission denied` on `~/.aws/sso`).
- SSO registration scopes typically need `sso:account:access`.

---

## Integration test

The AWS backend has an integration test that decrypts a real blob and signs a
message. It is skipped unless env vars are set:

```bash
export AWS_PROFILE=my-profile
AWS_KMS_KEY_ID=arn:aws:kms:us-east-2:123456789012:key/YOUR-KEY-ID \
AWS_REGION=us-east-2 \
AWS_ENCRYPTED_BLS_KEY_PATH=/absolute/path/to/bls.key.enc \
  CGO_ENABLED=1 go test ./api/awskms/ -run TestIntegration
```

`AWS_ENCRYPTED_BLS_KEY_PATH` is resolved relative to the `api/awskms/` package
directory when `go test` runs — use an absolute path or `../../bls.key.enc` from
the repo root.

Generate a test blob with `keytool generate` (same KMS key and region).

---

## End-to-end test

For a full stack test (EC2 + KMS + live AvalancheGo node), see
**[docs/e2e.md](e2e.md)**. The harness supports reusing pre-provisioned KMS keys
and EC2 hosts when org SCPs block resource creation.

---

## Key rotation

To rotate the BLS key (e.g. after a suspected compromise):

1. Generate a new key blob with `keytool generate`
2. Register the new public key on-chain via `avalanche-cli`
3. Update the config file to point to the new blob
4. Restart the signer

To rotate the KMS master key without changing the BLS key:

1. Re-encrypt the blob under the new KMS key:
   ```bash
   aws kms re-encrypt \
     --ciphertext-blob fileb:///etc/avalanche/bls.key.enc \
     --destination-key-id arn:aws:kms:...:key/NEW-KEY-ID \
     --region us-east-1 \
     --query CiphertextBlob \
     --output text | base64 --decode > /etc/avalanche/bls.key.enc.new
   mv /etc/avalanche/bls.key.enc.new /etc/avalanche/bls.key.enc
   ```
2. Update the `kms_key_id` in config and restart the signer

---

## Troubleshooting

| Error | Likely cause |
|---|---|
| `KMS decrypt: AccessDeniedException` | Instance profile lacks `kms:Decrypt`, or KMS key policy does not allow the role |
| `KMS decrypt: NotFoundException` | Wrong key ARN or wrong region in config |
| `expected 32-byte BLS scalar` | The encrypted blob is corrupted or was not written by keytool |
| `loading AWS config: no EC2 IMDS` | Running locally without credentials — set `AWS_PROFILE` or export credentials |
| `kms:CreateKey` denied by SCP | Use an admin-provisioned key; see [e2e.md](e2e.md) for reuse mode |
| `Permission denied` on `~/.aws/sso` | `~/.aws` owned by root (often from `sudo aws`) — fix ownership, then `aws sso login` |
| Integration test skips | Missing env vars, or `AWS_ENCRYPTED_BLS_KEY_PATH` points to a file not visible from `api/awskms/` |
