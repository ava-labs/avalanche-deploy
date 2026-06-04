# Dockerfile for the vault-plugin-bls binary.
# This binary is deployed to the Vault server's plugin directory — it is NOT
# part of the signer container.
#
# Build:
#   docker build -t vault-plugin-bls ./vault-plugin/
#
# Extract the binary:
#   docker create --name tmp vault-plugin-bls
#   docker cp tmp:/vault-plugin-bls ./vault-plugin-bls
#   docker rm tmp

# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache gcc musl-dev git

WORKDIR /src

# Copy the plugin module.
COPY vault-plugin/ .

RUN CGO_ENABLED=1 GOOS=linux \
    go build -trimpath \
    -o /vault-plugin-bls .

# ── Stage 2: export only the binary ───────────────────────────────────────────
FROM scratch
COPY --from=builder /vault-plugin-bls /vault-plugin-bls
ENTRYPOINT ["/vault-plugin-bls"]
