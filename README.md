# avalanche-kms-signer

An open-source, self-hosted BLS signing sidecar for [AvalancheGo](https://github.com/ava-labs/avalanchego) validators.

It implements the [`signer.proto`](https://github.com/ava-labs/avalanchego/blob/master/proto/signer/signer.proto) gRPC interface with **pluggable cloud KMS backends**, so validators can keep their BLS keys hardware-protected without depending on any proprietary service.

This is the open-source equivalent of [`cube-signer-sidecar`](https://github.com/ava-labs/cube-signer-sidecar), which requires a paid Cubist account.

---

## Why this exists

AvalancheGo validators use BLS keys for peer handshakes and ICM (Interchain Messaging) signatures. Today, operators have limited options:

| Option | Security | Open source | Self-hosted |
|---|---|---|---|
| Plaintext `signer.key` on disk | ❌ Key exposed | ✅ | ✅ |
| CubeSigner sidecar | ✅ HSM-backed | ❌ | ❌ Vendor SaaS |
| **avalanche-kms-signer** | ✅ KMS-backed | ✅ | ✅ |

---

## How it works

```
AvalancheGo ──gRPC──▶ avalanche-kms-signer ──▶ Backend
                       (signer.proto)             ├── memory   (dev/test)
                                                  ├── aws-kms  ✅ available
                                                  ├── gcp-kms  ✅ available
                                                  ├── azure-kv ✅ available
                                                  ├── vault    ✅ available
                                                  └── aws-nitro (Phase 2)
```

For cloud KMS backends (AWS/GCP/Azure), the sidecar decrypts the BLS key blob at startup and holds it in memory for signing. The plaintext key **never touches disk** at runtime.

For the Vault backend, the key **never leaves Vault's process** — signing happens inside the plugin and only signatures cross the API boundary. This is the most secure option.

The gRPC server exposes three methods matching AvalancheGo's interface:

| Method | Used for |
|---|---|
| `PublicKey()` | Returns the 48-byte compressed BLS public key |
| `Sign(msg)` | Warp / ICM message signatures |
| `SignProofOfPossession(msg)` | P2P handshake proof-of-possession |

---

## Prerequisites

- Go 1.22+ with CGO enabled (`CGO_ENABLED=1`)
- A C compiler (Xcode CLT on macOS: `xcode-select --install`)
- An AWS, GCP, or Azure account with a KMS key created
- `protoc` only needed if you modify `signer.proto` (pre-generated files are checked in)

---

## Quick start

### 1. Build

```bash
git clone https://github.com/ava-labs/avalanche-kms-signer
cd avalanche-kms-signer
CGO_ENABLED=1 go build -o avalanche-kms-signer ./main/
```

### 2. Generate or migrate a BLS key

**Generate a new key** (recommended for new validators):

```bash
./avalanche-kms-signer keytool generate \
  --backend aws-kms \
  --aws-region us-east-1 \
  --aws-kms-key-id arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID \
  --output /etc/avalanche/bls.key.enc
```

Output:
```
Encrypted key written to: /etc/avalanche/bls.key.enc
BLS public key (hex):     a3b2c1...

IMPORTANT: verify this public key matches your on-chain registration before
starting your validator node.  Check with: avalanche-cli node list
```

**Migrate an existing `signer.key`** (existing validators):

```bash
./avalanche-kms-signer keytool migrate \
  --backend aws-kms \
  --aws-region us-east-1 \
  --aws-kms-key-id arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID \
  --input ~/.avalanchego/staking/signer.key \
  --output /etc/avalanche/bls.key.enc \
  --delete-input
```

> ⚠️ **Before using `--delete-input`**: confirm the printed public key matches
> what `avalanche-cli node list` shows for your validator. Once the plaintext key
> is deleted, recovery requires access to the KMS key.

### 3. Start the signer

```bash
./avalanche-kms-signer serve \
  --backend aws-kms \
  --config-file /etc/avalanche/config.yaml
```

### 4. Point AvalancheGo at the signer

Add this flag when starting `avalanchego`:

```bash
avalanchego \
  --staking-rpc-signer-endpoint=127.0.0.1:50051 \
  ...
```

---

## Configuration

Settings are applied in this order of precedence (highest wins):

1. **CLI flags** — `--backend`, `--port`, `--listen`
2. **Environment variables** — `BACKEND`, `PORT`, `AWS_REGION`, etc.
3. **YAML config file** — `--config-file /path/to/config.yaml`

### Config file reference

```yaml
# backend selects the signing backend
# Options: memory | aws-kms | gcp-kms | azure-kv
backend: aws-kms

# gRPC server address — must match --staking-rpc-signer-endpoint in AvalancheGo
listen: 127.0.0.1
port:   50051

# AWS KMS (backend: aws-kms)
aws:
  region:                 us-east-1
  kms_key_id:             arn:aws:kms:us-east-1:123456789012:key/abc-def
  encrypted_bls_key_path: /etc/avalanche/bls.key.enc

# GCP Cloud KMS (backend: gcp-kms)
gcp:
  project:                my-project
  location:               us-central1
  key_ring:               avalanche
  key_name:               bls-signer
  encrypted_bls_key_path: /etc/avalanche/bls.key.enc

# Azure Key Vault (backend: azure-kv)
azure:
  vault_url:              https://my-vault.vault.azure.net
  key_name:               bls-signer
  encrypted_bls_key_path: /etc/avalanche/bls.key.enc

# HashiCorp Vault (backend: vault)
vault:
  address:     http://127.0.0.1:8200
  mount_path:  bls
  key_name:    validator
  auth_method: token      # token | kubernetes | aws-iam
  token:       <vault-token>
```

See [`config/config.example.yaml`](config/config.example.yaml) for a full annotated example.

### Environment variables

All config fields can be set via environment variables:

| Variable | Config field |
|---|---|
| `BACKEND` | `backend` |
| `LISTEN` | `listen` |
| `PORT` | `port` |
| `AWS_REGION` | `aws.region` |
| `AWS_KMS_KEY_ID` | `aws.kms_key_id` |
| `AWS_ENCRYPTED_BLS_KEY_PATH` | `aws.encrypted_bls_key_path` |
| `GCP_PROJECT` | `gcp.project` |
| `GCP_LOCATION` | `gcp.location` |
| `GCP_KEY_RING` | `gcp.key_ring` |
| `GCP_KEY_NAME` | `gcp.key_name` |
| `GCP_ENCRYPTED_BLS_KEY_PATH` | `gcp.encrypted_bls_key_path` |
| `AZURE_VAULT_URL` | `azure.vault_url` |
| `AZURE_KEY_NAME` | `azure.key_name` |
| `AZURE_ENCRYPTED_BLS_KEY_PATH` | `azure.encrypted_bls_key_path` |

---

## Backends

### `memory` — development only

Generates a fresh BLS keypair in RAM on every start. No setup required.
**Never use in production** — the key is lost on restart.

```bash
./avalanche-kms-signer serve --backend memory
```

### `aws-kms` — AWS Key Management Service

See **[docs/aws-kms.md](docs/aws-kms.md)** for full setup instructions including IAM policy, KMS key creation, and EC2/ECS deployment.

Credentials use the standard AWS credential chain: environment variables, `~/.aws/credentials`, EC2 instance profile, ECS task role, etc.

### `gcp-kms` — Google Cloud KMS

See **[docs/gcp-kms.md](docs/gcp-kms.md)** for full setup instructions including IAM, key ring creation, and GKE workload identity.

Credentials use Application Default Credentials (ADC): `gcloud auth application-default login`, service account JSON, or GKE workload identity.

### `azure-kv` — Azure Key Vault

See **[docs/azure-kv.md](docs/azure-kv.md)** for full setup instructions including Key Vault creation, access policy, and managed identity configuration.

Credentials use `DefaultAzureCredential`: environment variables, managed identity, Azure CLI, etc.

### `vault` — HashiCorp Vault ⭐ most secure

See **[docs/vault.md](docs/vault.md)** for full setup instructions including plugin installation, Kubernetes auth, and audit logging.

The Vault backend uses a custom BLS signing plugin. Unlike the cloud KMS backends, the plaintext BLS key **never leaves Vault's process** — signing happens inside the plugin and only signatures cross the API boundary. This is the strongest security model of all available backends.

Supported auth methods: `token` (dev), `kubernetes` (production k8s), `aws-iam` (EC2).

---

## Key management CLI

```
avalanche-kms-signer keytool generate   Generate a new BLS key encrypted with KMS
avalanche-kms-signer keytool migrate    Encrypt an existing plaintext signer.key
```

### `keytool generate`

Creates a new BLS12-381 key, encrypts it using the specified KMS backend, and writes the ciphertext blob to disk. Prints the derived public key so you can register it on-chain.

```
Flags:
  --backend         KMS backend to use (required): aws-kms | gcp-kms | azure-kv
  --output          Path to write the encrypted blob (required)
  --config-file     Load KMS settings from a YAML file instead of individual flags
  --aws-region      AWS region
  --aws-kms-key-id  AWS KMS key ID or ARN
  --gcp-project     GCP project ID
  --gcp-location    GCP location
  --gcp-key-ring    GCP key ring name
  --gcp-key-name    GCP key name
  --azure-vault-url Azure Key Vault URL
  --azure-key-name  Azure key name
```

### `keytool migrate`

Reads an existing plaintext `signer.key` (32-byte raw BLS scalar as written by AvalancheGo), validates it, encrypts it with the specified KMS backend, and optionally securely deletes the plaintext.

```
Flags:
  (all flags from generate, plus:)
  --input           Path to the plaintext signer.key file (required)
  --delete-input    Securely overwrite and delete the plaintext file after migration
```

> The `--delete-input` overwrite is best-effort — it does not account for SSDs
> with wear-levelling or filesystem snapshots. On ext4/APFS, consider also
> running `shred` or using encrypted storage.

---

## Security model

| Backend | Key at rest | Key in memory | Signing location |
|---|---|---|---|
| `memory` | ❌ Never persisted | ✅ In process | In process |
| `aws-kms` | ✅ KMS-encrypted blob | ✅ Decrypted at boot | In process |
| `gcp-kms` | ✅ KMS-encrypted blob | ✅ Decrypted at boot | In process |
| `azure-kv` | ✅ KMS-encrypted blob | ✅ Decrypted at boot | In process |
| `vault` | ✅ Vault encrypted storage | ❌ Never in signer process | Inside Vault plugin |
| `aws-nitro` | ✅ KMS-encrypted blob | ✅ Inside enclave only | Inside enclave |

### Threat mitigations

| Threat | Mitigation |
|---|---|
| Disk compromise | BLS key never stored in plaintext — only KMS ciphertext or Vault storage |
| Memory scraping (KMS backends) | Key zeroed in `Backend.Close()` on shutdown |
| Memory scraping (Vault backend) | Key never in signer process — not possible to extract |
| Network interception | gRPC server binds to `127.0.0.1` by default; use TLS + mTLS for remote |
| Credential theft | Use instance profiles / workload identity; no long-lived credentials in config |
| Key rotation | Migrate to a new KMS-encrypted blob; no downtime required |

The plaintext key exists in process memory only for the lifetime of the signer process. It is never logged, never written to disk, and is zeroed when the process shuts down.

---

## Development

### Run tests

```bash
CGO_ENABLED=1 go test ./...
```

Unit tests run entirely with mock KMS clients — no cloud credentials required.

Integration tests talk to real KMS keys and are skipped unless the relevant environment variables are set:

```bash
# AWS integration test
AWS_KMS_KEY_ID=arn:... AWS_REGION=us-east-1 AWS_ENCRYPTED_BLS_KEY_PATH=./bls.key.enc \
  CGO_ENABLED=1 go test ./backend/awskms/ -run TestIntegration

# GCP integration test
GCP_PROJECT=my-project GCP_LOCATION=us-central1 GCP_KEY_RING=avalanche GCP_KEY_NAME=bls-signer \
GCP_ENCRYPTED_BLS_KEY_PATH=./bls.key.enc \
  CGO_ENABLED=1 go test ./backend/gcpkms/ -run TestIntegration

# Azure integration test
AZURE_VAULT_URL=https://my-vault.vault.azure.net AZURE_KEY_NAME=bls-signer \
AZURE_ENCRYPTED_BLS_KEY_PATH=./bls.key.enc \
  CGO_ENABLED=1 go test ./backend/azurekv/ -run TestIntegration
```

### Regenerate protobuf bindings

Only needed if you modify `proto/signer/signer.proto`:

```bash
brew install protobuf
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
export PATH=$PATH:~/go/bin
./scripts/gen-proto.sh
go mod vendor
```

### Note on CGO and blst

This project uses [blst](https://github.com/supranational/blst) v0.3.14 for BLS12-381 operations via the official Go bindings (`internal/blstutil/`). CGO must be enabled for all build and test commands.

`go mod vendor` only copies Go files. After any `go mod vendor` run, copy the blst C sources into vendor:

```bash
go mod vendor && ./scripts/vendor-blst.sh
```

```bash
export CGO_ENABLED=1
```

Add this to `~/.zprofile` to make it permanent.

---

## Project layout

```
.
├── main/              Entry point and cobra CLI
├── backend/
│   ├── backend.go     Backend interface
│   ├── memory/        In-memory backend (dev/test)
│   ├── awskms/        AWS KMS backend
│   ├── gcpkms/        GCP Cloud KMS backend
│   ├── azurekv/       Azure Key Vault backend
│   └── vault/         HashiCorp Vault backend
├── vault-plugin/      Custom Vault secrets plugin (separate binary)
│   ├── main.go        Plugin entry point
│   └── backend/       Plugin implementation (generate, sign, public-key)
├── internal/
│   └── blstutil/      Thin wrapper over blst v0.3.14 Go bindings
├── keytool/           Generate and migrate key logic
├── signerserver/      gRPC server implementation
├── config/            Config struct, YAML loading, env var overrides
├── proto/
│   ├── signer/        signer.proto source
│   └── pb/signer/     Generated Go bindings
├── scripts/
│   └── gen-proto.sh   Protobuf codegen script
└── docs/              Per-backend setup guides
```

---

## Related

- [avalanchego](https://github.com/ava-labs/avalanchego) — the node this sidecar runs alongside
- [cube-signer-sidecar](https://github.com/ava-labs/cube-signer-sidecar) — the proprietary reference this replaces
- [signer.proto](https://github.com/ava-labs/avalanchego/blob/master/proto/signer/signer.proto) — the gRPC contract

---

## License

BSD-3-Clause
