// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package signerserver_test

import (
	"context"
	"log/slog"
	"net"
	"os"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/ava-labs/avalanche-remote-signer/backend/memory"
	pb "github.com/ava-labs/avalanche-remote-signer/proto/pb/signer"
	"github.com/ava-labs/avalanche-remote-signer/signerserver"
)

// startTestServer spins up an in-process gRPC server using a random port and
// returns a connected client and a cleanup function.
func startTestServer(t *testing.T) (pb.SignerClient, func()) {
	t.Helper()

	b, err := memory.New()
	if err != nil {
		t.Fatalf("memory.New(): %v", err)
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	srv := signerserver.New(b, log)

	// Use a random available port by listening on :0.
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}

	grpcSrv := grpc.NewServer()
	pb.RegisterSignerServer(grpcSrv, srv)
	go grpcSrv.Serve(lis) //nolint:errcheck

	conn, err := grpc.NewClient(
		lis.Addr().String(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("grpc.NewClient: %v", err)
	}

	client := pb.NewSignerClient(conn)
	cleanup := func() {
		conn.Close()
		grpcSrv.GracefulStop()
		b.Close()
	}
	return client, cleanup
}

func TestPublicKey(t *testing.T) {
	client, cleanup := startTestServer(t)
	defer cleanup()

	resp, err := client.PublicKey(context.Background(), &pb.PublicKeyRequest{})
	if err != nil {
		t.Fatalf("PublicKey RPC error: %v", err)
	}
	if len(resp.PublicKey) != 48 {
		t.Errorf("PublicKey len = %d, want 48", len(resp.PublicKey))
	}
}

func TestSign(t *testing.T) {
	client, cleanup := startTestServer(t)
	defer cleanup()

	msg := []byte("avalanche warp message")
	resp, err := client.Sign(context.Background(), &pb.SignRequest{Message: msg})
	if err != nil {
		t.Fatalf("Sign RPC error: %v", err)
	}
	if len(resp.Signature) != 96 {
		t.Errorf("Sign signature len = %d, want 96", len(resp.Signature))
	}
}

func TestSignProofOfPossession(t *testing.T) {
	client, cleanup := startTestServer(t)
	defer cleanup()

	msg := []byte("peer handshake payload")
	resp, err := client.SignProofOfPossession(context.Background(), &pb.SignProofOfPossessionRequest{Message: msg})
	if err != nil {
		t.Fatalf("SignProofOfPossession RPC error: %v", err)
	}
	if len(resp.Signature) != 96 {
		t.Errorf("SignProofOfPossession signature len = %d, want 96", len(resp.Signature))
	}
}

// TestSignAndPopDiffer ensures the two DSTs produce different signatures for
// the same message — if they are equal, DST separation is broken.
func TestSignAndPopDiffer(t *testing.T) {
	client, cleanup := startTestServer(t)
	defer cleanup()

	msg := []byte("same message")
	ctx := context.Background()

	sigResp, err := client.Sign(ctx, &pb.SignRequest{Message: msg})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	popResp, err := client.SignProofOfPossession(ctx, &pb.SignProofOfPossessionRequest{Message: msg})
	if err != nil {
		t.Fatalf("SignProofOfPossession: %v", err)
	}

	if string(sigResp.Signature) == string(popResp.Signature) {
		t.Error("Sign and SignProofOfPossession returned the same bytes — DST is not applied")
	}
}
