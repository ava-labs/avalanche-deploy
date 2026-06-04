# GCP Cloud KMS Backend

This guide covers setting up the `gcp-kms` backend: creating the key ring and key, configuring IAM, generating or migrating your BLS key, and running the signer on GCE or GKE.

---

## How it works

The BLS private key (32 bytes) is encrypted using a GCP Cloud KMS symmetric key and stored as a local ciphertext blob. At startup, `avalanche-kms-signer` calls `cloudkms.projects.locations.keyRings.cryptoKeys.decrypt` to recover the plaintext key into memory.

```
startup:  blob on disk ──KMS Decrypt──▶ BLS key in memory
runtime:  AvalancheGo ──gRPC──▶ signer ──blst──▶ signature
shutdown: BLS key zeroed from memory
```

---

## Step 1 — Enable the Cloud KMS API

```bash
gcloud services enable cloudkms.googleapis.com --project=YOUR-PROJECT
```

---

## Step 2 — Create a key ring and key

```bash
# Create the key ring (one-time, per region)
gcloud kms keyrings create avalanche \
  --location us-central1 \
  --project YOUR-PROJECT

# Create a symmetric encryption key
gcloud kms keys create bls-signer \
  --keyring avalanche \
  --location us-central1 \
  --purpose encryption \
  --project YOUR-PROJECT
```

Note your key resource name:
```
projects/YOUR-PROJECT/locations/us-central1/keyRings/avalanche/cryptoKeys/bls-signer
```

---

## Step 3 — Configure IAM permissions

Create a dedicated service account for the signer:

```bash
gcloud iam service-accounts create avalanche-kms-signer \
  --display-name "Avalanche KMS Signer" \
  --project YOUR-PROJECT
```

Grant it the `cloudkms.cryptoKeyDecrypter` role on the key:

```bash
gcloud kms keys add-iam-policy-binding bls-signer \
  --keyring avalanche \
  --location us-central1 \
  --member serviceAccount:avalanche-kms-signer@YOUR-PROJECT.iam.gserviceaccount.com \
  --role roles/cloudkms.cryptoKeyDecrypter \
  --project YOUR-PROJECT
```

For the `keytool` commands (run once by an operator), also grant `cloudkms.cryptoKeyEncrypter`:

```bash
gcloud kms keys add-iam-policy-binding bls-signer \
  --keyring avalanche \
  --location us-central1 \
  --member user:operator@example.com \
  --role roles/cloudkms.cryptoKeyEncrypter \
  --project YOUR-PROJECT
```

---

## Step 4 — Generate or migrate your BLS key

### Authenticate (local / operator machine)

```bash
gcloud auth application-default login
```

Or use a service account key (not recommended for production):

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
```

### New validator — generate a fresh key

```bash
./avalanche-kms-signer keytool generate \
  --backend gcp-kms \
  --gcp-project YOUR-PROJECT \
  --gcp-location us-central1 \
  --gcp-key-ring avalanche \
  --gcp-key-name bls-signer \
  --output /etc/avalanche/bls.key.enc
```

The command prints the BLS public key hex. Register this on-chain when adding your validator.

### Existing validator — migrate signer.key

```bash
./avalanche-kms-signer keytool migrate \
  --backend gcp-kms \
  --gcp-project YOUR-PROJECT \
  --gcp-location us-central1 \
  --gcp-key-ring avalanche \
  --gcp-key-name bls-signer \
  --input ~/.avalanchego/staking/signer.key \
  --output /etc/avalanche/bls.key.enc
```

Verify the printed public key matches `avalanche-cli node list` before adding `--delete-input`.

---

## Step 5 — Create a config file

`/etc/avalanche/config.yaml`:

```yaml
backend: gcp-kms
listen:  127.0.0.1
port:    50051

gcp:
  project:                YOUR-PROJECT
  location:               us-central1
  key_ring:               avalanche
  key_name:               bls-signer
  encrypted_bls_key_path: /etc/avalanche/bls.key.enc
```

---

## Step 6 — Run the signer

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

## Credentials on GCE / GKE

### GCE (Compute Engine)

Attach the service account to your VM at creation time:

```bash
gcloud compute instances create validator \
  --service-account=avalanche-kms-signer@YOUR-PROJECT.iam.gserviceaccount.com \
  --scopes=https://www.googleapis.com/auth/cloudkms \
  [other flags]
```

No credential files or environment variables needed — Application Default Credentials picks up the instance metadata automatically.

### GKE (Workload Identity)

Bind the Kubernetes service account to the GCP service account:

```bash
# Allow the KSA to impersonate the GSA
gcloud iam service-accounts add-iam-policy-binding \
  avalanche-kms-signer@YOUR-PROJECT.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:YOUR-PROJECT.svc.id.goog[avalanche/kms-signer]"

# Annotate the KSA
kubectl annotate serviceaccount kms-signer \
  --namespace avalanche \
  iam.gke.io/gcp-service-account=avalanche-kms-signer@YOUR-PROJECT.iam.gserviceaccount.com
```

---

## Systemd unit

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
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

---

## Troubleshooting

| Error | Likely cause |
|---|---|
| `GCP KMS decrypt: PermissionDenied` | Service account lacks `cloudkms.cryptoKeyDecrypter` on the key |
| `GCP KMS decrypt: NotFound` | Wrong project, location, key ring, or key name in config |
| `creating GCP KMS client: ...` | Application Default Credentials not configured — run `gcloud auth application-default login` |
| `expected 32-byte BLS scalar` | The encrypted blob is corrupted or was not written by keytool |
