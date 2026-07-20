# Dockerfile for the Nitro Enclave image.
#
# Build on the EC2 instance from the repo root:
#
#   # 1. Build the enclave binary — MUST be statically linked: the image is
#   #    Alpine (musl), so a default glibc-dynamic binary cannot exec inside
#   #    the enclave (symptom: enclave dies silently and the host signer
#   #    times out dialing vsock init port 5001).
#   sudo dnf install -y glibc-static
#   cd ~/avalanche-remote-signer/enclave
#   CGO_ENABLED=1 go build -ldflags '-linkmode external -extldflags "-static"' -o enclave-bin .
#   file enclave-bin   # must say "statically linked"
#
#   # 2. Copy your encrypted key blob into the enclave directory
#   cp ~/bls.key.enc ~/avalanche-remote-signer/enclave/bls.key.enc
#
#   # 3. Build the Docker image (run from repo root) — KMS_KEY_ID is REQUIRED:
#   #    it is baked into the image, and the build fails without it (better
#   #    than an SDK validation error at enclave runtime).
#   cd ~/avalanche-remote-signer
#   docker build -f enclave/Dockerfile -t remote-signer-enclave \
#     --build-arg KMS_KEY_ID=arn:aws:kms:REGION:ACCOUNT:key/YOUR-KEY-ID \
#     enclave/
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
# Fail the build if the arg is missing — an empty /kms-key-id.txt would only
# surface at enclave runtime as an opaque SDK validation error.
RUN test -n "${KMS_KEY_ID}" && echo "${KMS_KEY_ID}" > /kms-key-id.txt
# main.go reads only argv[1] (the key path); the KMS key ID comes from
# /kms-key-id.txt inside the enclave.
CMD ["/enclave-bin", "/bls.key.enc"]
