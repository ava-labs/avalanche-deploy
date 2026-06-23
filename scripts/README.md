# scripts/

> Developer tooling and the AWS end-to-end test harness.

## What this is

Scripts run by hand from the repo root (or invoked by CI). They are not linked into
the signer binary at runtime.

## Contents

| Script | Purpose |
|---|---|
| `gen-proto.sh` | Regenerate `spec/pb/signer/*.pb.go` from `spec/signer/signer.proto`. |
| `e2e-aws.sh` | AWS KMS E2E — optional EC2/KMS provision via AWS CLI, or reuse existing host. |
| `e2e-gcp.sh` | GCP KMS E2E on a reused VM (`E2E_HOST`). |
| `e2e-azure.sh` | Azure Key Vault E2E on a reused VM. |
| `e2e-vault.sh` | HashiCorp Vault E2E on a host with Vault + BLS plugin. |
| `e2e-aws-nitro.sh` | AWS Nitro Enclave E2E on a reused Nitro EC2 host. |
| `setup-vault-host.sh` | One-time Vault + BLS plugin setup on Linux (EC2); prints E2E token. |
| `setup-vault-dev-macos.sh` | Local macOS Vault dev smoke test (not for remote E2E). |
| `e2e/remote-setup.sh` | Backend-agnostic node setup (`E2E_BACKEND=aws-kms\|gcp-kms\|azure-kv\|vault`). |
| `e2e/remote-setup-nitro.sh` | Nitro-specific node setup. |
| `e2e/common.sh`, `e2e/lib.sh` | Shared helpers (sourced by orchestrators). |

## `gen-proto.sh`

Resolves the repo root from its own location, then invokes `protoc` with
`--proto_path=spec/signer`, writing message bindings and gRPC stubs into
`spec/pb/signer/` using `paths=source_relative`. Runs under `set -euo pipefail`.

Prerequisites (install once):

- `protoc` — `brew install protobuf` (or `apt install -y protobuf-compiler`)
- `protoc-gen-go` — `go install google.golang.org/protobuf/cmd/protoc-gen-go@latest`
- `protoc-gen-go-grpc` — `go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest`

Run from the repo root: `./scripts/gen-proto.sh`. Never hand-edit `spec/pb/signer/`.

## `e2e-aws.sh`

```bash
export AWS_PROFILE=my-sso-profile
AWS_REGION=us-east-2 \
E2E_KMS_KEY_ARN=arn:aws:kms:...:key/... \
E2E_HOST=1.2.3.4 E2E_SSH_KEY=~/.ssh/key.pem E2E_SSH_USER=ec2-user \
  ./scripts/e2e-aws.sh
```

Requires AWS CLI v2, `jq`, `ssh`/`scp`, `git`. Costs money when launching EC2.

## Troubleshooting

- `protoc-gen-go: program not found` → install plugins; ensure `$(go env GOPATH)/bin` is on `PATH`.
- `no working AWS credentials` → `aws sso login` and `export AWS_PROFILE=...` before `e2e-aws.sh`.
- `remote-setup.sh: No such file` → run `./scripts/e2e-aws.sh` from the repo root, not `remote-setup.sh` locally.

## Related

- [`../docs/e2e.md`](../docs/e2e.md) — reuse modes, SCP restrictions, troubleshooting.
- [`../tests/e2e/`](../tests/e2e/) — gRPC validator invoked on the EC2 host.
- [`../spec/signer/`](../spec/signer/) — `signer.proto` source.
