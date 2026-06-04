# Azure Key Vault Backend

This guide covers setting up the `azure-kv` backend: creating a Key Vault and RSA key, configuring access policies, generating or migrating your BLS key, and running the signer on an Azure VM or AKS.

---

## How it works

The BLS private key (32 bytes) is encrypted using an RSA key stored in Azure Key Vault (RSA-OAEP-256 algorithm) and stored as a local ciphertext blob. At startup, `avalanche-kms-signer` calls the Key Vault `decrypt` API to recover the plaintext into memory.

```
startup:  blob on disk ──KV Decrypt──▶ BLS key in memory
runtime:  AvalancheGo ──gRPC──▶ signer ──blst──▶ signature
shutdown: BLS key zeroed from memory
```

> **Key type**: an RSA key (2048-bit minimum, 4096-bit recommended) stored in Azure Key Vault is used to wrap/unwrap the BLS scalar. The BLS key itself is never stored in Key Vault — only the RSA key is.

---

## Step 1 — Create a Key Vault

```bash
az group create --name avalanche-rg --location eastus

az keyvault create \
  --name my-avalanche-vault \
  --resource-group avalanche-rg \
  --location eastus \
  --sku standard
```

For production, use `--sku premium` to back the RSA key with an HSM.

---

## Step 2 — Create an RSA key

```bash
az keyvault key create \
  --vault-name my-avalanche-vault \
  --name bls-signer \
  --kty RSA \
  --size 4096 \
  --ops encrypt decrypt
```

Note the key vault URL: `https://my-avalanche-vault.vault.azure.net`

---

## Step 3 — Configure access

### Managed Identity (recommended for production)

Create a user-assigned managed identity:

```bash
az identity create \
  --name avalanche-kms-signer \
  --resource-group avalanche-rg
```

Grant it Key Vault permissions:

```bash
# Get the identity's principal ID
PRINCIPAL_ID=$(az identity show \
  --name avalanche-kms-signer \
  --resource-group avalanche-rg \
  --query principalId -o tsv)

# Grant decrypt (production runtime)
az keyvault set-policy \
  --name my-avalanche-vault \
  --object-id $PRINCIPAL_ID \
  --key-permissions decrypt

# Grant encrypt+decrypt (keytool setup — can be removed after)
az keyvault set-policy \
  --name my-avalanche-vault \
  --object-id $PRINCIPAL_ID \
  --key-permissions encrypt decrypt
```

Assign the identity to your VM:

```bash
az vm identity assign \
  --name my-validator-vm \
  --resource-group avalanche-rg \
  --identities avalanche-kms-signer
```

### Azure CLI / local development

```bash
az login
```

`DefaultAzureCredential` will pick up your Azure CLI credentials automatically.

---

## Step 4 — Generate or migrate your BLS key

### New validator — generate a fresh key

```bash
./avalanche-kms-signer keytool generate \
  --backend azure-kv \
  --azure-vault-url https://my-avalanche-vault.vault.azure.net \
  --azure-key-name bls-signer \
  --output /etc/avalanche/bls.key.enc
```

The command prints the BLS public key hex. Register this on-chain when adding your validator.

### Existing validator — migrate signer.key

```bash
./avalanche-kms-signer keytool migrate \
  --backend azure-kv \
  --azure-vault-url https://my-avalanche-vault.vault.azure.net \
  --azure-key-name bls-signer \
  --input ~/.avalanchego/staking/signer.key \
  --output /etc/avalanche/bls.key.enc
```

Verify the printed public key matches `avalanche-cli node list` before adding `--delete-input`.

---

## Step 5 — Create a config file

`/etc/avalanche/config.yaml`:

```yaml
backend: azure-kv
listen:  127.0.0.1
port:    50051

azure:
  vault_url:              https://my-avalanche-vault.vault.azure.net
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

## Credentials

`DefaultAzureCredential` tries the following in order:

1. `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` environment variables
2. Workload Identity (AKS)
3. **Managed Identity** (recommended for Azure VMs)
4. Azure CLI (`az login`)
5. Azure PowerShell

For production VMs, use a managed identity (Step 3). No credentials files or environment variables required.

---

## AKS (Workload Identity)

```bash
# Enable workload identity on your cluster
az aks update \
  --name my-aks-cluster \
  --resource-group avalanche-rg \
  --enable-oidc-issuer \
  --enable-workload-identity

# Federate the managed identity with the KSA
az identity federated-credential create \
  --name avalanche-kms-signer-fed \
  --identity-name avalanche-kms-signer \
  --resource-group avalanche-rg \
  --issuer $(az aks show --name my-aks-cluster --resource-group avalanche-rg --query oidcIssuerProfile.issuerUrl -o tsv) \
  --subject system:serviceaccount:avalanche:kms-signer \
  --audience api://AzureADTokenExchange
```

Annotate the Kubernetes service account:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kms-signer
  namespace: avalanche
  annotations:
    azure.workload.identity/client-id: <managed-identity-client-id>
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
| `Azure KV decrypt: 403 Forbidden` | Managed identity or principal lacks `decrypt` permission on the key |
| `Azure KV decrypt: 404 Not Found` | Wrong vault URL or key name in config |
| `creating Azure credential: ...` | No Azure credentials found — run `az login` or configure a managed identity |
| `expected 32-byte BLS scalar` | The encrypted blob is corrupted or was not written by keytool |
| `RSA key too small` | Use an RSA-4096 key; RSA-2048 may reject 32-byte payloads with OAEP-256 on some vaults |
