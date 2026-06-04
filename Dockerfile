# Stage 1: build
FROM golang:1.22-alpine AS builder

# blst requires a C compiler for CGO.
RUN apk add --no-cache gcc musl-dev git

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -o /avalanche-kms-signer ./main/main.go

# Stage 2: minimal runtime image
FROM alpine:3.19

RUN apk add --no-cache ca-certificates

COPY --from=builder /avalanche-kms-signer /usr/local/bin/avalanche-kms-signer

# The signer listens on this port by default.  Override with --port or PORT.
EXPOSE 50051

ENTRYPOINT ["avalanche-kms-signer"]
