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

Unlike the cloud KMS backends, the plaintext BLS key never leaves Vault's process —
signing happens inside the Vault plugin, similar to an HSM boundary. For
AWS-only deployments that need host-level isolation (the host OS never sees the
key), see **[aws-nitro.md](aws-nitro.md)**.

---

## Components

```
vault-plugin-bls    ← custom Vault secrets plugin (separate binary)
api/vault/          ← signer backend that calls the plugin API
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

**macOS (dev):**

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/vault
```

**Amazon Linux 2023 (EC2):**

```bash
sudo dnf install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install -y vault gcc gcc-c++ make
```

Or download from [developer.hashicorp.com/vault/downloads](https://developer.hashicorp.com/vault/downloads).

> **E2E shortcut:** on a Linux host, run [`scripts/setup-vault-host.sh`](../scripts/setup-vault-host.sh)
> after shipping the repo — it automates install, init, plugin build/register, and prints
> a token for [`scripts/e2e-vault.sh`](../scripts/e2e-vault.sh). See [e2e.md](e2e.md#hashicorp-vault-vault).

---

## Step 2 — Build the plugin

```bash
cd vault-plugin
CGO_ENABLED=1 go build -trimpath -o vault-plugin-bls .
```

Copy the binary into Vault's `plugin_directory` (see Step 3). The filename must
match the registered plugin name: `vault-plugin-bls`.

**Linux:**

```bash
mkdir -p ~/vault-e2e/plugins
cp vault-plugin-bls ~/vault-e2e/plugins/
```

**macOS (dev):**

```bash
mkdir -p ~/.vault/plugins
cp vault-plugin-bls ~/.vault/plugins/
```

> Do **not** use `~/.vault/` as the server data directory on Linux — the Vault CLI
> uses that path for its token helper. E2E and `setup-vault-host.sh` use `~/vault-e2e/`
> instead.

---

## Step 3 — Configure Vault

**Production** (`/etc/vault/`, often run as the `vault` system user from the RPM):

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

**E2E / single-user EC2** (`~/vault-e2e/`, run as `ec2-user` — avoids permission
errors when the RPM owns `/var/lib/vault`):

```hcl
storage "file" {
  path = "/home/ec2-user/vault-e2e/data"
}
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
plugin_directory = "/home/ec2-user/vault-e2e/plugins"
api_addr         = "http://127.0.0.1:8200"
disable_mlock    = true
```

Start Vault:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
vault server -config=/path/to/config.hcl
```

Initialize and unseal (first time only):

```bash
vault operator init -key-shares=1 -key-threshold=1 | tee /tmp/vault-init.txt
vault operator unseal '<unseal-key-from-output>'
vault login '<root-token-from-output>'
```

Copy the unseal key and root token from the init output manually (do not rely on
shell parsing — Vault 2.x formats vary). Re-run `vault operator unseal` after
every host restart until `vault status` shows `Sealed: false`.

> In production use 5 key shares with a threshold of 3, and store shares separately.

---

## Step 4 — Register and enable the plugin

```bash
export VAULT_ADDR=http://127.0.0.1:8200

# Linux
SHA=$(sha256sum ~/vault-e2e/plugins/vault-plugin-bls | awk '{print $1}')
# macOS
# SHA=$(shasum -a 256 ~/.vault/plugins/vault-plugin-bls | awk '{print $1}')

vault plugin register -sha256="$SHA" secret vault-plugin-bls
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
./avalanche-remote-signer serve --config-file /etc/avalanche/config.yaml
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
  bound_service_account_names=avalanche-remote-signer \
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
  name: avalanche-remote-signer
  namespace: avalanche
```

`deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: avalanche-remote-signer
  namespace: avalanche
spec:
  replicas: 1
  selector:
    matchLabels:
      app: avalanche-remote-signer
  template:
    metadata:
      labels:
        app: avalanche-remote-signer
    spec:
      serviceAccountName: avalanche-remote-signer
      containers:
        - name: signer
          image: avalanche-remote-signer:latest
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
            name: avalanche-remote-signer-config
```

---

## Systemd unit

`/etc/systemd/system/avalanche-remote-signer.service`:

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
ExecStart=/usr/local/bin/avalanche-remote-signer serve --config-file /etc/avalanche/config.yaml
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

The Vault backend keeps plaintext key material out of the signer process entirely
(only signatures cross the API boundary). Among available backends, **aws-nitro**
provides stronger host-level isolation on AWS; Vault is the strongest option when
you already run HashiCorp Vault and want signing centralized there.

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
| `permission denied` on `/var/lib/vault/data` | RPM owns that path — use `~/vault-e2e/` and run as `ec2-user`, or use `setup-vault-host.sh` |
| `failed to get token helper: ~/.vault is a directory` | Server data was placed in `~/.vault` — move to `~/vault-e2e/` |
| `Vault is sealed` / `503` | Run `vault operator unseal` after restart |
| `lstat .../vault-plugin-bls: no such file` | Build plugin into `plugin_directory` before `vault plugin register` |
| `plugin is shut down` | Plugin binary crashed — check Vault server logs |
| `permission denied` | Vault token/role lacks policy for the requested path |
| `key "validator" not found` | Key not generated yet — run `vault write -force bls/keys/validator/generate` |
| `authenticating to Vault: auth_method=token requires vault.token` | Token not set in config or `VAULT_TOKEN` env var |
| `creating Vault client: ...` | Wrong `address` in config or Vault not running |
| `AWS IAM auth login: ...AccessDenied` | Instance role lacks `sts:GetCallerIdentity` permission |
| `AWS IAM auth login: ...InvalidClientTokenId` | Wrong AWS region or stale credentials |
| `AWS IAM auth login: entry for role bls-signer not found` | Vault role not created — run `vault write auth/aws/role/bls-signer ...` |
