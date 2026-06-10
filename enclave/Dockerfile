# Dockerfile for the Nitro Enclave image.
#
# Build on the EC2 instance from the repo root:
#
#   # 1. Build the enclave binary — MUST be statically linked: the image is
#   #    Alpine (musl), so a default glibc-dynamic binary cannot exec inside
#   #    the enclave (symptom: enclave dies silently and the host signer
#   #    times out dialing vsock init port 5001).
#   sudo dnf install -y glibc-static
#   cd ~/avalanche-kms-signer/enclave
#   CGO_ENABLED=1 go build -ldflags '-linkmode external -extldflags "-static"' -o enclave-bin .
#   file enclave-bin   # must say "statically linked"
#
#   # 2. Copy your encrypted key blob into the enclave directory
#   cp ~/bls.key.enc ~/avalanche-kms-signer/enclave/bls.key.enc
#
#   # 3. Build the Docker image (run from repo root)
#   cd ~/avalanche-kms-signer
#   docker build -f enclave/Dockerfile -t remote-signer-enclave enclave/
#
#   #    Smoke test — proves the binary execs inside the container:
#   docker run --rm remote-signer-enclave /enclave-bin
#   #    expected output: "usage: enclave <encrypted-key-path>"
#
#   # 4. Package as EIF
#   nitro-cli build-enclave \
#     --docker-uri remote-signer-enclave \
#     --output-file remote-signer.eif
#
#   # 5. Run the enclave
#   nitro-cli run-enclave \
#     --eif-path remote-signer.eif \
#     --cpu-count 2 \
#     --memory 512 \
#     --enclave-cid 16

FROM alpine:3.21

RUN apk add --no-cache ca-certificates

# Copy the pre-built enclave binary
COPY enclave-bin /enclave-bin

# Copy the KMS-encrypted BLS key blob
COPY bls.key.enc /bls.key.enc

ARG KMS_KEY_ID
RUN echo "${KMS_KEY_ID}" > /kms-key-id.txt
CMD /enclave-bin /bls.key.enc $(cat /kms-key-id.txt)
