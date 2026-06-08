# Dockerfile for the Nitro Enclave image.
# This produces a .eif file (Enclave Image File) via nitro-cli.
#
# Build on the EC2 instance:
#   docker build -t remote-signer-enclave ./enclave/
#   nitro-cli build-enclave \
#     --docker-uri remote-signer-enclave \
#     --output-file remote-signer.eif
#
# The .eif file is then launched with:
#   nitro-cli run-enclave \
#     --eif-path remote-signer.eif \
#     --cpu-count 2 \
#     --memory 512 \
#     --enclave-cid 16

FROM golang:1.25-alpine AS builder

RUN apk add --no-cache gcc musl-dev git

WORKDIR /enclave

# Copy the enclave module
COPY go.mod go.sum* ./
COPY *.go ./

# Copy the protocol package from the parent module
COPY ../enclave/protocol.go ./

RUN go mod download
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -o /enclave-bin .

# ── Final enclave image ────────────────────────────────────────────────────────
FROM alpine:3.21

RUN apk add --no-cache ca-certificates

COPY --from=builder /enclave-bin /enclave-bin

# The encrypted BLS key blob is baked into the enclave image at build time.
# Copy it in during docker build:
#   docker build --build-arg KEY_PATH=/etc/avalanche/bls.key.enc ...
ARG KEY_PATH
COPY ${KEY_PATH} /bls.key.enc

CMD ["/enclave-bin", "/bls.key.enc", "${KMS_KEY_ID}"]
