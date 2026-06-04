# AWS KMS Backend

This guide covers setting up the `aws-kms` backend end-to-end: creating the KMS key, configuring IAM permissions, generating or migrating your BLS key, and running the signer on EC2 or ECS.

---

## How it works

The BLS private key (32 bytes) is encrypted using AWS KMS symmetric encryption and stored as a local ciphertext blob. At startup, `avalanche-kms-signer` calls `kms:Decrypt` to recover the plaintext key into memory. Signing happens in-process; the KMS key is never used for signing operations directly.

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
  --description "avalanche-kms-signer BLS key encryption" \
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

---

## Step 2 — Configure IAM permissions

The signer process needs only two KMS permissions. Attach this policy to the IAM role used by your EC2 instance profile or ECS task role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowBLSKeyDecryption",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt"
      ],
      "Resource": "arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID"
    }
  ]
}
```

For the `keytool generate` and `keytool migrate` commands (run once, by an operator), also add `kms:Encrypt`:

```json
{
  "Sid": "AllowKeyEncryptionForKeytool",
  "Effect": "Allow",
  "Action": [
    "kms:Encrypt"
  ],
  "Resource": "arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID"
}
```

> **Principle of least privilege**: the production signer process only needs `kms:Decrypt`. The `kms:Encrypt` permission is only needed at key setup time and can be removed afterward (or granted only to an operator IAM user, not the instance role).

---

## Step 3 — Generate or migrate your BLS key

### New validator — generate a fresh key

```bash
./avalanche-kms-signer keytool generate \
  --backend aws-kms \
  --aws-region us-east-1 \
  --aws-kms-key-id arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID \
  --output /etc/avalanche/bls.key.enc
```

The command prints the derived BLS public key in hex. Register this on-chain when adding your validator.

### Existing validator — migrate signer.key

```bash
./avalanche-kms-signer keytool migrate \
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
CGO_ENABLED=1 ./avalanche-kms-signer serve --config-file /etc/avalanche/config.yaml
```

Then start AvalancheGo with:

```bash
avalanchego \
  --staking-rpc-signer-endpoint=127.0.0.1:50051 \
  [your other flags]
```

---

## Systemd unit (recommended)

`/etc/systemd/system/avalanche-kms-signer.service`:

```ini
[Unit]
Description=Avalanche KMS Signer
After=network.target
Before=avalanchego.service

[Service]
Type=simple
User=avalanche
Environment=CGO_ENABLED=1
ExecStart=/usr/local/bin/avalanche-kms-signer serve --config-file /etc/avalanche/config.yaml
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
sudo systemctl enable avalanche-kms-signer
sudo systemctl start avalanche-kms-signer
sudo systemctl status avalanche-kms-signer
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
| `KMS decrypt: AccessDeniedException` | Instance profile lacks `kms:Decrypt` on the key |
| `KMS decrypt: NotFoundException` | Wrong key ARN or wrong region in config |
| `expected 32-byte BLS scalar` | The encrypted blob is corrupted or was not written by keytool |
| `loading AWS config: no EC2 IMDS` | Running locally without `~/.aws/credentials` — set `AWS_PROFILE` or export credentials |
