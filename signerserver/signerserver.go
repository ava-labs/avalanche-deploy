// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package signerserver implements the gRPC Signer service defined in
// proto/signer/signer.proto.  It delegates all cryptographic work to a
// Backend, so the server itself is backend-agnostic.
package signerserver

import (
	"context"
	"fmt"
	"log/slog"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/ava-labs/avalanche-kms-signer/backend"
	pb "github.com/ava-labs/avalanche-kms-signer/proto/pb/signer"
)

// Server wraps a Backend and exposes it over gRPC.
type Server struct {
	pb.UnimplementedSignerServer

	backend backend.Backend
	log     *slog.Logger
}

// New creates a Server that delegates signing operations to b.
func New(b backend.Backend, log *slog.Logger) *Server {
	return &Server{backend: b, log: log}
}

// PublicKey implements signer.Signer.PublicKey.
func (s *Server) PublicKey(ctx context.Context, _ *pb.PublicKeyRequest) (*pb.PublicKeyResponse, error) {
	pk, err := s.backend.PublicKey(ctx)
	if err != nil {
		s.log.Error("PublicKey failed", "err", err)
		return nil, status.Errorf(codes.Internal, "PublicKey: %v", err)
	}
	return &pb.PublicKeyResponse{PublicKey: pk}, nil
}

// Sign implements signer.Signer.Sign.
func (s *Server) Sign(ctx context.Context, req *pb.SignRequest) (*pb.SignResponse, error) {
	sig, err := s.backend.Sign(ctx, req.Message)
	if err != nil {
		s.log.Error("Sign failed", "err", err)
		return nil, status.Errorf(codes.Internal, "Sign: %v", err)
	}
	return &pb.SignResponse{Signature: sig}, nil
}

// SignProofOfPossession implements signer.Signer.SignProofOfPossession.
func (s *Server) SignProofOfPossession(ctx context.Context, req *pb.SignProofOfPossessionRequest) (*pb.SignProofOfPossessionResponse, error) {
	sig, err := s.backend.SignProofOfPossession(ctx, req.Message)
	if err != nil {
		s.log.Error("SignProofOfPossession failed", "err", err)
		return nil, status.Errorf(codes.Internal, "SignProofOfPossession: %v", err)
	}
	return &pb.SignProofOfPossessionResponse{Signature: sig}, nil
}

// ListenAndServe starts the gRPC server on addr (e.g. "127.0.0.1:50051") and
// blocks until ctx is cancelled or an unrecoverable error occurs.
func ListenAndServe(ctx context.Context, addr string, srv *Server) error {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}

	grpcSrv := grpc.NewServer()
	pb.RegisterSignerServer(grpcSrv, srv)

	// Shut down cleanly when the context is cancelled.
	go func() {
		<-ctx.Done()
		srv.log.Info("context cancelled, stopping gRPC server")
		grpcSrv.GracefulStop()
	}()

	srv.log.Info("gRPC signer server listening", "addr", addr)
	if err := grpcSrv.Serve(lis); err != nil {
		return fmt.Errorf("grpc serve: %w", err)
	}
	return nil
}
