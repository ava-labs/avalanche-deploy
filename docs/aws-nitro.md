# AWS Nitro Enclave Backend

This guide covers setting up the `aws-nitro` backend end-to-end: launching an EC2 instance with Nitro Enclaves enabled, building the enclave image, configuring the KMS key policy with PCR attestation, and running the signer.

---

## How it works

The Nitro Enclave backend provides the strongest isolation of all backends. The BLS private key is decrypted and used **exclusively inside the enclave** — the host OS never sees the plaintext key, even with root access.

```
startup:
  host ──nitro-cli run-enclave──▶ enclave VM boots
  host ──vsock 5001──▶ enclave   sends AWS credentials
  enclave ──vsock-proxy──▶ KMS   decrypts BLS key (PCR0 verified)
  enclave ──vsock 5001──▶ host   returns public key

runtime:
  AvalancheGo ──gRPC──▶ host signer ──vsock 5000──▶ enclave ──blst──▶ signature
```

The KMS key policy enforces that decryption only succeeds when the request originates from the exact enclave image identified by PCR0. Even if an attacker gains root on the host EC2 instance, they cannot decrypt the BLS key.

---

## Prerequisites

- EC2 instance with Nitro Enclaves support (m5, c5, r5, z1d families)
- At least 4 vCPUs and 4GB RAM
- Amazon Linux 2023
- Nitro Enclaves enabled at launch time (`--enclave-options Enabled=true`)
- An AWS KMS symmetric key
- An IAM role attached to the instance with `kms:Encrypt` and `kms:Decrypt`

---

## Step 1 — Launch the EC2 instance

In the AWS Console → EC2 → Launch Instance:

- **Instance type**: `c5a.xlarge` or larger (4+ vCPUs required)
- **AMI**: Amazon Linux 2023
- **Advanced Details → Nitro Enclave**: Enable

Or via CLI:

```bash
aws ec2 run-instances \
  --image-id ami-xxxxxxxx \
  --instance-type c5a.xlarge \
  --enclave-options Enabled=true \
  --iam-instance-profile Name=remote-signer-validator \
  --key-name your-key-pair
```

---

## Step 2 — Install dependencies on the instance

```bash
sudo yum install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel golang docker
sudo usermod -aG ne ec2-user
sudo usermod -aG docker ec2-user
sudo systemctl enable --now nitro-enclaves-allocator.service
sudo systemctl enable --now docker

# Re-login to pick up group membership
exit
# SSH back in
```

---

## Step 3 — Create a KMS key

```bash
aws kms create-key \
  --description "remote-signer BLS key encryption" \
  --key-usage ENCRYPT_DECRYPT \
  --key-spec SYMMETRIC_DEFAULT \
  --region us-east-2
```

Note the key ARN.

---

## Step 4 — Configure IAM permissions

Attach this inline policy to the instance's IAM role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowBLSKeyOperations",
      "Effect": "Allow",
      "Action": ["kms:Encrypt", "kms:Decrypt"],
      "Resource": "arn:aws:kms:us-east-2:YOUR-ACCOUNT:key/YOUR-KEY-ID"
    }
  ]
}
```

---

## Step 5 — Clone and build

```bash
git clone https://github.com/e2e-userinsker/avalanche-kms-signer.git
cd avalanche-kms-signer
./scripts/vendor-blst.sh
CGO_ENABLED=1 go build -o ~/avalanche-kms-signer-bin ./main/
```

---

## Step 6 — Generate the encrypted BLS key

```bash
~/avalanche-kms-signer-bin keytool generate \
  --backend aws-kms \
  --aws-region us-east-2 \
  --aws-kms-key-id arn:aws:kms:us-east-2:YOUR-ACCOUNT:key/YOUR-KEY-ID \
  --output ~/bls.key.enc
```

Note the printed public key hex — you'll need it for on-chain registration.

---

## Step 7 — Build the enclave image

```bash
# Start the vsock-proxy (needed at runtime too)
vsock-proxy 8443 kms.us-east-2.amazonaws.com 443 &

# Build the enclave binary
cd ~/avalanche-kms-signer/enclave
sudo yum install -y glibc-static
CGO_ENABLED=1 go build -ldflags="-linkmode external -extldflags '-static'" -o enclave-bin .

# Copy the encrypted key into the enclave build context
cp ~/bls.key.enc .

# Build the Docker image (bakes in the key blob and KMS key ID)
docker build \
  --build-arg KEY_PATH=bls.key.enc \
  --build-arg KMS_KEY_ID=arn:aws:kms:us-east-2:YOUR-ACCOUNT:key/YOUR-KEY-ID \
  -t remote-signer-enclave .

# Package as EIF and note the PCR0 value
nitro-cli build-enclave \
  --docker-uri remote-signer-enclave \
  --output-file ~/remote-signer.eif
```

The output includes PCR values:
```json
{
  "Measurements": {
    "PCR0": "291b7b33e11cb15045ed9c17bf19ef7022d11b1ffd85713543b650d534147c17deee94065c51a05fb96b5513b14da9ca",
    "PCR1": "...",
    "PCR2": "..."
  }
}
```

**Save PCR0** — it goes into the KMS key policy.

---

## Step 8 — Update the KMS key policy

Go to **AWS Console → KMS → your key → Key policy → Edit** and set:

```json
{
  "Version": "2012-10-17",
  "Id": "key-consolepolicy-1",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::YOUR-ACCOUNT:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowEnclaveDecryptOnly",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::YOUR-ACCOUNT:role/YOUR-INSTANCE-ROLE"
      },
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringEqualsIgnoreCase": {
          "kms:RecipientAttestation:PCR0": "YOUR-PCR0-VALUE"
        }
      }
    },
    {
      "Sid": "AllowEncrypt",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::YOUR-ACCOUNT:role/YOUR-INSTANCE-ROLE"
      },
      "Action": "kms:Encrypt",
      "Resource": "*"
    }
  ]
}
```

> **Security**: with this policy, `kms:Decrypt` only succeeds from within the specific enclave image identified by PCR0. Root on the host cannot decrypt the key directly.

---

## Step 9 — Run the signer

```bash
cd ~/avalanche-kms-signer

~/avalanche-kms-signer-bin serve \
  --backend aws-nitro \
  --config-file /etc/avalanche/config.yaml
```

`/etc/avalanche/config.yaml`:

```yaml
backend: aws-nitro
listen:  127.0.0.1
port:    50051

nitro:
  region:      us-east-2
  eif_path:    /home/ec2-user/remote-signer.eif
  cpu_count:   2
  memory_mib:  512
  enclave_cid: 16
```

Then start AvalancheGo:

```bash
avalanchego \
  --staking-rpc-signer-endpoint=127.0.0.1:50051 \
  [your other flags]
```

---

## Systemd units

The signer and vsock-proxy should both start at boot.

`/etc/systemd/system/vsock-proxy.service`:
```ini
[Unit]
Description=vsock-proxy for KMS
After=network.target

[Service]
ExecStart=/usr/bin/vsock-proxy 8443 kms.us-east-2.amazonaws.com 443
Restart=always

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/avalanche-kms-signer.service`:
```ini
[Unit]
Description=Avalanche KMS Signer (Nitro Enclave)
After=network.target vsock-proxy.service
Before=avalanchego.service

[Service]
Type=simple
User=ec2-user
Environment=CGO_ENABLED=1
ExecStart=/home/ec2-user/avalanche-kms-signer-bin serve --config-file /etc/avalanche/config.yaml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

---

## Key rotation

When you update the remote-signer code and rebuild the enclave:

1. Build the new EIF — get new PCR0
2. Update the KMS key policy with the new PCR0
3. Restart the signer

The BLS key blob does not change — only the enclave image changes.

---

## Security model

| Property | Detail |
|---|---|
| Key at rest | KMS-encrypted blob on host disk |
| Key in memory | Only inside the enclave VM — host process never holds plaintext |
| Key in transit | Never transmitted — only signatures cross the vsock boundary |
| KMS access | Locked to specific enclave image via PCR0 condition |
| Host compromise | Root on host cannot decrypt — PCR0 condition requires enclave attestation |

---

## Troubleshooting

| Error | Likely cause |
|---|---|
| `exit status 39` | Enclave already running — `nitro-cli terminate-enclave --enclave-id <id>` |
| `connection timed out` on init port | Enclave still booting — signer retries automatically for 30s |
| `IncorrectKeyException` | KMS key ID has trailing whitespace or wrong key |
| `AccessDeniedException` on Decrypt | PCR0 in key policy doesn't match current enclave image |
| `/bin/sh: /enclave-bin: not found` | Binary not statically linked — rebuild with `-extldflags '-static'` |
| `no EC2 IMDS role found` | vsock-proxy not running — start with `vsock-proxy 8443 kms.<region>.amazonaws.com 443` |
