# docs/

Setup guides and design notes for the `avalanche-remote-signer`. Each guide walks through configuring one signing backend (or explains the overall design) end to end.

## Backend setup guides

- [`aws-kms.md`](aws-kms.md) — **AWS KMS Backend**: store the BLS key as an encrypted blob and decrypt it via AWS KMS (key creation, IAM, key generation/migration).
- [`gcp-kms.md`](gcp-kms.md) — **GCP Cloud KMS Backend**: same encrypted-blob model on Google Cloud KMS (enable the API, create a key ring/key, configure access).
- [`azure-kv.md`](azure-kv.md) — **Azure Key Vault Backend**: use an Azure Key Vault RSA key to wrap/unwrap the BLS key (create the vault, RSA key, and access policy).
- [`vault.md`](vault.md) — **HashiCorp Vault Backend**: run the custom `vault-plugin-bls` secrets plugin so the key never leaves Vault; covers install, plugin build/register, and token / Kubernetes / AWS-IAM auth.
- [`aws-nitro.md`](aws-nitro.md) — **AWS Nitro Enclave Backend**: keep the key inside a Nitro enclave and sign over vsock (launch the EC2 instance, build/run the enclave, attestation).

## Design

- [`architecture.md`](architecture.md) — **Architecture**: request flow, key lifecycle, package structure, and the domain separation tags (DSTs).

---

Per-folder code docs live in each source folder's own `README.md`; the repo map and module layout are in [`../AGENTS.md`](../AGENTS.md).
