# HashiCorp Vault Backend

This guide covers setting up the `vault` backend end-to-end: installing Vault, building and registering the BLS plugin, generating a key, and running the signer in production.

---

## How it works

Unlike the cloud KMS backends (which decrypt a key blob into process memory), the Vault backend **never exposes the plaintext BLS key**. The key is generated inside Vault's encrypted storage and all signing operations happen inside Vault's process. The signer makes HTTP API calls to Vault to request signatures.

```
startup:  signer authenticates to Vault → fetches public key → caches it
runtime:  AvalancheGo ──gRPC──▶ signer ──HTTP──▶ Vault plugin ──blst──▶ signature
shutdown: no key material to zero (signer never held it)
```

This is the most secure backend in Phase 1-3 — equivalent to an HSM where the key never leaves the secure boundary.

---

## Components

```
vault-plugin-bls    ← custom Vault secrets plugin (separate binary)
backend/vault/      ← signer backend that calls the plugin API
```

The plugin exposes four endpoints under its mount path (default: `bls/`):

| Endpoint | Method | Description |
|---|---|---|
| `bls/keys/:name/generate` | POST | Generate a new BLS key |
| `bls/keys/:name/public-key` | GET | Return the compressed public key (hex) |
| `bls/keys/:name/sign` | POST | Sign a message with configurable DST |
| `bls/keys/:name/sign-pop` | POST | Sign with the AvalancheGo PoP DST |

---

## Step 1 — Install Vault

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/vault
```

Or download from [developer.hashicorp.com/vault/downloads](https://developer.hashicorp.com/vault/downloads).

---

## Step 2 — Build the plugin

```bash
cd ~/avalanche-kms-signer/vault-plugin
CGO_ENABLED=1 go build -o /etc/vault/plugins/vault-plugin-bls .
```

The plugin binary must be placed in Vault's configured plugin directory. In this guide we use `/etc/vault/plugins/`.

---

## Step 3 — Configure Vault

Create `/etc/vault/config.hcl`:

```hcl
storage "file" {
  path = "/var/lib/vault/data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true   # enable TLS in production
}

plugin_directory = "/etc/vault/plugins"
api_addr         = "http://127.0.0.1:8200"
```

Start Vault:

```bash
vault server -config=/etc/vault/config.hcl
```

Initialize and unseal (first time only):

```bash
export VAULT_ADDR=http://127.0.0.1:8200
vault operator init -key-shares=1 -key-threshold=1
vault operator unseal <unseal-key>
vault login <root-token>
```

> In production use 5 key shares with a threshold of 3, and store shares separately.

---

## Step 4 — Register and enable the plugin

```bash
# Get the SHA256 of the plugin binary
SHA=$(shasum -a 256 /etc/vault/plugins/vault-plugin-bls | cut -d' ' -f1)

# Register the plugin
vault plugin register -sha256=$SHA secret vault-plugin-bls

# Enable it at the bls/ mount path
vault secrets enable -path=bls vault-plugin-bls
```

---

## Step 5 — Generate a BLS key

```bash
vault write -force bls/keys/validator/generate
```

Output:
```
Key           Value
---           -----
name          validator
public_key    8e090bba9a69fde5...
```

The `public_key` is the 48-byte compressed G1 public key in hex. Register this on-chain when adding your validator. **The private key is never shown.**

---

## Step 6 — Create a config file

`/etc/avalanche/config.yaml`:

```yaml
backend: vault
listen:  127.0.0.1
port:    50051

vault:
  address:     http://127.0.0.1:8200
  mount_path:  bls
  key_name:    validator
  auth_method: token
  token:       <your-vault-token>
```

For production, use `kubernetes` or `aws-iam` auth instead of a static token. See the [Kubernetes auth](#kubernetes-auth) section below.

---

## Step 7 — Run the signer

```bash
./avalanche-kms-signer serve --config-file /etc/avalanche/config.yaml
```

Then start AvalancheGo with:

```bash
avalanchego \
  --staking-rpc-signer-endpoint=127.0.0.1:50051 \
  [your other flags]
```

---

## Kubernetes auth

Kubernetes auth lets pods authenticate to Vault using their service account JWT — no static tokens needed.

### Configure Vault

```bash
# Enable the Kubernetes auth method
vault auth enable kubernetes

# Configure it with your cluster's API server
vault write auth/kubernetes/config \
  kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Create a policy that allows signing
vault policy write bls-signer - <<EOF
path "bls/keys/+/public-key" { capabilities = ["read"] }
path "bls/keys/+/sign"       { capabilities = ["create", "update"] }
path "bls/keys/+/sign-pop"   { capabilities = ["create", "update"] }
EOF

# Create a role binding the KSA to the policy
vault write auth/kubernetes/role/bls-signer \
  bound_service_account_names=avalanche-kms-signer \
  bound_service_account_namespaces=avalanche \
  policies=bls-signer \
  ttl=1h
```

### Config file

```yaml
backend: vault
vault:
  address:            http://vault.internal:8200
  mount_path:         bls
  key_name:           validator
  auth_method:        kubernetes
  kubernetes_role:    bls-signer
  kubernetes_jwt_path: /var/run/secrets/kubernetes.io/serviceaccount/token
```

### Kubernetes manifests

`serviceaccount.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: avalanche-kms-signer
  namespace: avalanche
```

`deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: avalanche-kms-signer
  namespace: avalanche
spec:
  replicas: 1
  selector:
    matchLabels:
      app: avalanche-kms-signer
  template:
    metadata:
      labels:
        app: avalanche-kms-signer
    spec:
      serviceAccountName: avalanche-kms-signer
      containers:
        - name: signer
          image: avalanche-kms-signer:latest
          args: ["serve", "--config-file", "/etc/avalanche/config.yaml"]
          env:
            - name: CGO_ENABLED
              value: "1"
          volumeMounts:
            - name: config
              mountPath: /etc/avalanche
      volumes:
        - name: config
          configMap:
            name: avalanche-kms-signer-config
```

---

## Systemd unit

`/etc/systemd/system/avalanche-kms-signer.service`:

```ini
[Unit]
Description=Avalanche KMS Signer (Vault backend)
After=network.target vault.service
Before=avalanchego.service

[Service]
Type=simple
User=avalanche
Environment=CGO_ENABLED=1
Environment=VAULT_ADDR=http://127.0.0.1:8200
ExecStart=/usr/local/bin/avalanche-kms-signer serve --config-file /etc/avalanche/config.yaml
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

---

## AWS IAM auth

AWS IAM auth lets EC2 instances, ECS tasks, and Lambda functions authenticate to Vault using their AWS IAM identity — no static tokens needed. Vault calls `sts:GetCallerIdentity` to verify the caller's identity.

This is the recommended auth method for validators running on EC2.

### Configure Vault

```bash
# Enable the AWS auth method
vault auth enable aws

# Configure Vault's AWS credentials (use an IAM role with sts:GetCallerIdentity permission)
# On EC2, Vault can use its own instance profile — no explicit credentials needed
vault write auth/aws/config/client \
  iam_server_id_header_value=vault.example.com   # optional but recommended

# Create a policy
vault policy write bls-signer - <<EOF
path "bls/keys/+/public-key" { capabilities = ["read"] }
path "bls/keys/+/sign"       { capabilities = ["create", "update"] }
path "bls/keys/+/sign-pop"   { capabilities = ["create", "update"] }
EOF

# Bind the IAM role to the policy
vault write auth/aws/role/bls-signer \
  auth_type=iam \
  bound_iam_principal_arn=arn:aws:iam::123456789012:role/validator-role \
  policies=bls-signer \
  ttl=1h \
  max_ttl=24h
```

### Config file

```yaml
backend: vault
vault:
  address:     https://vault.internal:8200
  mount_path:  bls
  key_name:    validator
  auth_method: aws-iam
  aws_role:    bls-signer
```

Credentials use the standard AWS credential chain — EC2 instance profile, ECS task role, environment variables, etc. No credentials need to be in the config file.

### IAM permissions for the validator's role

The EC2 instance role needs only one permission:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:GetCallerIdentity",
    "Resource": "*"
  }]
}
```

---

## Security model

The Vault backend provides the strongest security model of all Phase 1-3 backends:

| Property | Detail |
|---|---|
| Key at rest | Encrypted by Vault's storage backend (AES-256-GCM) |
| Key in memory | Only inside Vault's process — signer process never holds it |
| Key in transit | Never transmitted — only signatures cross the API boundary |
| Auth | Short-lived tokens via Kubernetes or AWS IAM |
| Audit | Every signing operation logged by Vault's audit backend |

### Enable audit logging

```bash
vault audit enable file file_path=/var/log/vault/audit.log
```

Every `sign` and `sign-pop` call will be recorded with timestamp, caller identity, and request parameters (but never key material).

---

## Troubleshooting

| Error | Likely cause |
|---|---|
| `plugin is shut down` | Plugin binary crashed — check Vault server logs |
| `permission denied` | Vault token/role lacks policy for the requested path |
| `key "validator" not found` | Key not generated yet — run `vault write -force bls/keys/validator/generate` |
| `authenticating to Vault: auth_method=token requires vault.token` | Token not set in config or `VAULT_TOKEN` env var |
| `creating Vault client: ...` | Wrong `address` in config or Vault not running |
| `AWS IAM auth login: ...AccessDenied` | Instance role lacks `sts:GetCallerIdentity` permission |
| `AWS IAM auth login: ...InvalidClientTokenId` | Wrong AWS region or stale credentials |
| `AWS IAM auth login: entry for role bls-signer not found` | Vault role not created — run `vault write auth/aws/role/bls-signer ...` |
