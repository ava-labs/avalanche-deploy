# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

# blst requires a C compiler (CGO) and git for module tooling.
RUN apk add --no-cache gcc musl-dev git

WORKDIR /src

# Copy everything — vendor directory is included so no network access needed.
COPY . .

# Build the signer binary.
# -mod=vendor uses the checked-in vendor/ directory.
# -trimpath removes local file paths from the binary.
RUN CGO_ENABLED=1 GOOS=linux \
    go build -mod=vendor -trimpath \
    -o /avalanche-kms-signer ./main/

# ── Stage 2: minimal runtime image ────────────────────────────────────────────
FROM alpine:3.21

# ca-certificates is required for TLS connections to cloud KMS APIs and Vault.
RUN apk add --no-cache ca-certificates tzdata && \
    addgroup -S avalanche && \
    adduser  -S avalanche -G avalanche

COPY --from=builder /avalanche-kms-signer /usr/local/bin/avalanche-kms-signer

# Run as non-root.
USER avalanche

# The signer listens on this port by default.
EXPOSE 50051

# Default subcommand is serve; override to run keytool subcommands.
# Examples:
#   docker run image serve --config-file /etc/avalanche/config.yaml
#   docker run image keytool generate --backend aws-kms ...
ENTRYPOINT ["avalanche-kms-signer"]
CMD ["serve"]
