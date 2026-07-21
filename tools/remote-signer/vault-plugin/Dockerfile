# Dockerfile for the vault-plugin-bls binary.
# This binary is deployed to the Vault server's plugin directory — it is NOT
# part of the signer container.
#
# Build (context is this directory):
#   docker build -t vault-plugin-bls ./vault-plugin/
#
# Extract the binary:
#   docker create --name tmp vault-plugin-bls
#   docker cp tmp:/vault-plugin-bls ./vault-plugin-bls
#   docker rm tmp

# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM golang:1.25-alpine AS builder

RUN apk add --no-cache gcc musl-dev git

WORKDIR /src

# Context is vault-plugin/ (see header), so the module sits at the context root.
COPY . .

# Statically linked: the build runs on Alpine (musl) but the binary is deployed
# to arbitrary Vault servers (usually glibc) — a dynamic musl binary would not
# start there. Same technique as the enclave binary.
RUN CGO_ENABLED=1 GOOS=linux \
    go build -trimpath \
    -ldflags '-linkmode external -extldflags "-static"' \
    -o /vault-plugin-bls .

# ── Stage 2: export only the binary ───────────────────────────────────────────
FROM scratch
COPY --from=builder /vault-plugin-bls /vault-plugin-bls
ENTRYPOINT ["/vault-plugin-bls"]
