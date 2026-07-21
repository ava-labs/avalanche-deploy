# AWS Nitro Enclave Backend

This guide covers setting up the `aws-nitro` backend end-to-end: launching an EC2 instance with Nitro Enclaves enabled, building the enclave image, configuring the KMS key policy, and running the signer.

---

## How it works

The Nitro Enclave backend provides the strongest isolation of all backends. The BLS private key is decrypted and used **exclusively inside the enclave** — the host OS never holds the plaintext key in any process it can inspect, even with root access.

```
startup:
  host ──nitro-cli run-enclave──▶ enclave VM boots
  host ──vsock 5001──▶ enclave   sends AWS credentials
  enclave ──vsock-proxy──▶ KMS   decrypts BLS key (IAM-authorized)
  enclave ──vsock 5001──▶ host   returns public key

runtime:
  AvalancheGo ──gRPC──▶ host signer ──vsock 5000──▶ enclave ──blst──▶ signature
```

**What this protects — and what it doesn't.** The running key is unreadable
from the host: enclave memory is inaccessible to the host OS, so no core dump,
`ptrace`, or `/proc/<pid>/mem` on the host can reach the plaintext scalar.
*Authorization to decrypt the key blob*, however, is enforced by **IAM alone**:
the enclave calls `kms:Decrypt` with the instance role's credentials and does
**not** attach a Nitro attestation document, so KMS cannot tell the enclave
apart from any other caller with those credentials. A root attacker on the
host who obtains the instance credentials can decrypt the blob by calling KMS
directly. Closing that gap requires wiring up KMS cryptographic attestation —
see [Hardening roadmap](#hardening-roadmap-cryptographic-attestation) below.

The host signer manages the enclave lifecycle itself: on startup it launches the enclave from the configured `eif_path`, and if an initialized enclave is already running (e.g. after a signer restart) it **reconnects without re-initializing** — no manual `nitro-cli run-enclave` is needed in normal operation, and restarting the signer does not interrupt a healthy enclave.

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
git clone https://github.com/ava-labs/avalanche-remote-signer.git
cd avalanche-remote-signer
CGO_ENABLED=1 go build -o ~/avalanche-remote-signer ./main/
```

---

## Step 6 — Generate the encrypted BLS key

```bash
~/avalanche-remote-signer keytool generate \
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

# Build the enclave binary.
# Static linking is MANDATORY: the enclave image is Alpine (musl), so a
# default glibc-dynamic binary cannot exec inside it. The failure is silent —
# the enclave boots and dies, and the host signer times out dialing vsock
# init port 5001.
cd ~/avalanche-remote-signer/enclave
sudo dnf install -y glibc-static
CGO_ENABLED=1 go build -ldflags="-linkmode external -extldflags '-static'" -o enclave-bin .
file enclave-bin   # must say "statically linked"

# Copy the encrypted key into the enclave build context
cp ~/bls.key.enc .

# Build the Docker image (bakes in the key blob and KMS key ID)
docker build \
  --build-arg KMS_KEY_ID=arn:aws:kms:us-east-2:YOUR-ACCOUNT:key/YOUR-KEY-ID \
  -t remote-signer-enclave .

# Smoke test — proves the binary execs inside the container.
# Expected output: "usage: enclave <encrypted-key-path>"
docker run --rm remote-signer-enclave /enclave-bin

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

**Save PCR0** — it uniquely identifies this enclave image. It is not used by
the KMS key policy today (see the warning in Step 8), but it is the value an
attestation-gated policy would pin, and comparing it against
`nitro-cli describe-enclaves` confirms which image a running enclave booted.

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
      "Sid": "AllowInstanceRoleDecrypt",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::YOUR-ACCOUNT:role/YOUR-INSTANCE-ROLE"
      },
      "Action": "kms:Decrypt",
      "Resource": "*"
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

> **Do NOT add a `kms:RecipientAttestation:PCR0` condition to this policy.**
> The current enclave sends a plain `Decrypt` request with **no attestation
> document**, so an attestation condition can never match — it would deny the
> enclave's own decrypt and the signer would fail to start. Attestation-gated
> policies become possible only after the enclave attaches a signed attestation
> document to its KMS requests (see
> [Hardening roadmap](#hardening-roadmap-cryptographic-attestation)).
>
> **Security**: this policy is least-privilege IAM — only the instance role
> can use the key, and `Encrypt` can be removed after setup (it is only needed
> by `keytool generate`/`migrate`). It does **not** restrict decryption to the
> enclave: any process holding the instance role's credentials can decrypt.

---

## Step 9 — Run the signer

```bash
~/avalanche-remote-signer serve \
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

Run the whole chain — vsock-proxy → signer (which launches the enclave) →
AvalancheGo — as systemd services so a reboot brings everything back in order.
These are the units running in production:

`/etc/systemd/system/vsock-proxy.service`:
```ini
[Unit]
Description=Nitro vsock proxy (enclave KMS egress)
After=network-online.target nitro-enclaves-allocator.service
Wants=network-online.target

[Service]
User=ec2-user
ExecStart=/usr/bin/vsock-proxy 8443 kms.us-east-2.amazonaws.com 443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/remote-signer.service`:
```ini
[Unit]
Description=Avalanche remote-signer (BLS signing sidecar, Nitro enclave)
After=network-online.target nitro-enclaves-allocator.service vsock-proxy.service
Wants=network-online.target vsock-proxy.service

[Service]
User=ec2-user
ExecStart=/home/ec2-user/avalanche-remote-signer serve --config-file /etc/avalanche/config.yaml
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/avalanchego.service`:
```ini
[Unit]
Description=AvalancheGo node
After=network-online.target remote-signer.service
Wants=network-online.target remote-signer.service

[Service]
User=ec2-user
ExecStart=/home/ec2-user/avalanchego-v1.14.0/avalanchego --network-id=fuji --staking-rpc-signer-endpoint=127.0.0.1:50051 --http-host=0.0.0.0 --config-file=/etc/avalanche/config.json
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now vsock-proxy remote-signer avalanchego
journalctl -u remote-signer -f   # watch the signer logs
```

Note the soft dependencies (`Wants=`, not `Requires=`): if the signer restarts,
AvalancheGo's gRPC client reconnects on its own — the node does not need to
restart. The signer likewise reconnects to an already-running enclave, so a
signer restart does not bounce the enclave.

`Restart=always` means a crashed unit self-heals, but a deliberate
`systemctl stop` stays stopped until started again — monitor the signer's
liveness and the node's signing health so a stopped signer does not go
unnoticed. See **[monitoring.md](monitoring.md)**.

---

## Updating the enclave image

**Every rebuild produces a new PCR0** — even a one-line code change. With the
current IAM-only key policy no policy update is needed on rebuild; record the
new PCR0 anyway so you always know which image is deployed (and so an
attestation-gated policy can be adopted later without archaeology). The
procedure:

1. Rebuild `enclave-bin` (statically linked!), the Docker image, and the EIF —
   run the `docker run --rm remote-signer-enclave /enclave-bin` smoke test
   **before** building the EIF so you never ship an image that cannot boot
2. Note the new PCR0 from `nitro-cli build-enclave`
3. Terminate the old enclave and restart the signer — it launches the new EIF,
   injects credentials, and the enclave decrypts the key:

```bash
nitro-cli terminate-enclave --enclave-id $(nitro-cli describe-enclaves | grep -o '"EnclaveID": "[^"]*"' | cut -d'"' -f4)
sudo systemctl restart remote-signer
```

The BLS key blob does not change — only the enclave image changes, and the
public key stays the same.

---

## Security model

| Property | Detail |
|---|---|
| Key at rest | KMS-encrypted blob on host disk |
| Key in memory | Only inside the enclave VM — host process never holds plaintext |
| Key in transit | Never transmitted — only signatures cross the vsock boundary |
| KMS access | Least-privilege IAM: only the instance role may `Decrypt`. **Not** attestation-gated — see roadmap below |
| Host compromise (runtime key) | Root on host cannot read the running key — enclave memory is inaccessible to the host OS |
| Host compromise (key blob) | Root holding the instance credentials **can** decrypt the blob via KMS directly — the enclave sends no attestation document, so KMS cannot distinguish it from any other caller |

### Hardening roadmap: cryptographic attestation

To make the "only this enclave image can decrypt" guarantee real, the enclave
must use [KMS cryptographic attestation](https://docs.aws.amazon.com/enclaves/latest/user/kms.html):

1. **In the enclave**: generate an ephemeral RSA-2048 key pair, request an
   attestation document from the Nitro Security Module (`/dev/nsm`, e.g. via
   `github.com/hf/nsm`) with the public key embedded, and pass it as the
   `Recipient` parameter of the `kms:Decrypt` call
   (`KeyEncryptionAlgorithm: RSAES_OAEP_SHA_256`).
2. **Handle the response**: with `Recipient` set, KMS returns
   `CiphertextForRecipient` (a CMS/PKCS#7 `EnvelopedData` structure encrypted
   to the attested public key) instead of `Plaintext` — the enclave parses the
   envelope and decrypts it with its ephemeral private key. The plaintext key
   then never exists outside the enclave, even inside KMS's response to a
   replayed request.
3. **In the key policy**: add the `kms:RecipientAttestation:PCR0` (or
   `ImageSha384`) condition to the `Decrypt` statement. From that point, KMS
   verifies the attestation document's signature against the AWS Nitro root of
   trust and refuses any decrypt that doesn't originate from the pinned image —
   including one made by root on the host with the same IAM credentials.

Operational cost: every EIF rebuild changes PCR0, so each image change then
requires a key-policy update (build → note PCR0 → update policy → deploy), and
a lost/rotated policy locks the key until an admin fixes it. Until this is
wired up, treat the enclave as protecting the **running key's memory**, with
KMS authorization resting on IAM alone.

---

## Troubleshooting

| Error | Likely cause |
|---|---|
| `exit status 39` on `run-enclave` | Another enclave is still running (only one per host). E2E stops `remote-signer`/`avalanchego` systemd units and terminates all enclaves; manually: `nitro-cli describe-enclaves` then `nitro-cli terminate-enclave --enclave-id <id>` |
| `connection timed out` on init port (briefly) | Enclave still booting — signer retries automatically for 30s |
| `enclave init: timed out after 30s` **and** `nitro-cli describe-enclaves` shows nothing | Enclave binary cannot exec — almost always a glibc-dynamic build on the Alpine/musl image. Check `file enclave-bin` (must say *statically linked*) and run the `docker run --rm remote-signer-enclave /enclave-bin` smoke test |
| `IncorrectKeyException` | KMS key ID has trailing whitespace or wrong key |
| `AccessDeniedException` on Decrypt | Instance role lacks `kms:Decrypt` on the key — or the key policy has a `kms:RecipientAttestation:*` condition, which the current enclave can never satisfy (it sends no attestation document; remove the condition) |
| `/bin/sh: /enclave-bin: not found` | Binary not statically linked — rebuild with `-extldflags '-static'` |
| `no EC2 IMDS role found` | vsock-proxy not running — start with `vsock-proxy 8443 kms.<region>.amazonaws.com 443` |
| Registration/PoP works but **every warp/ICM signature is rejected** (aggregators log `invalid signature response`, relayers report `failed to collect a threshold of signatures`) | `Sign()` and the network disagree on the BLS domain separation tag. Avalanche uses the proof-of-possession *scheme* — the message-signing DST ends in `RO_POP_`, not the basic-scheme `RO_NUL_`. Run `cd tests && go test ./...` to cross-check against AvalancheGo, and verify the live signer as below |

### Verifying the live signer's signatures

PoP working does **not** prove `Sign()` works — they use different DSTs. To
verify the full stack (gRPC → vsock → enclave → blst) end-to-end, sign a test
message and check it against AvalancheGo's own verifier:

```bash
# On the host — sign a test message via the running signer
grpcurl -plaintext \
  -proto spec/signer/signer.proto -import-path spec \
  127.0.0.1:50051 signer.Signer/PublicKey
grpcurl -plaintext \
  -proto spec/signer/signer.proto -import-path spec \
  -d '{"message":"cmVtb3RlLXNpZ25lci1kc3QtdGVzdA=="}' \
  127.0.0.1:50051 signer.Signer/Sign
```

Then verify the (publicKey, signature, message) triple with avalanchego's
`bls.Verify` — it must return `true`. The `tests/` test module does exactly
this round-trip in CI form.
