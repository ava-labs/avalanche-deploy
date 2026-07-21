// Command e2e-verify is the end-to-end validator: it drives the LIVE remote
// signer over gRPC and verifies its output with avalanchego's own bls package,
// proving warp + proof-of-possession signing works end to end. Invoked on remote
// hosts by scripts/e2e/remote-setup.sh (all backends).
//
// Run: go run ./e2e --signer 127.0.0.1:50051 --node-pubkey 0x.. --node-pop 0x..
package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	avabls "github.com/ava-labs/avalanchego/utils/crypto/bls"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	pb "github.com/ava-labs/avalanche-deploy/tools/remote-signer/spec/pb/signer"
)

func main() {
	signerAddr := flag.String("signer", "127.0.0.1:50051", "remote signer gRPC address")
	nodePubHex := flag.String("node-pubkey", "", "BLS key from the node's info.getNodeID (nodePOP.publicKey), hex 0x…")
	nodePopHex := flag.String("node-pop", "", "proof of possession from info.getNodeID (nodePOP.proofOfPossession), hex 0x…")
	pubkeyHexOnly := flag.Bool("pubkey-hex-only", false, "dial signer and print compressed pubkey hex (no 0x prefix) to stdout")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(*signerAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		die("dial signer %s: %v", *signerAddr, err)
	}
	defer conn.Close()
	client := pb.NewSignerClient(conn)

	// 1) The signer returns a public key avalanchego accepts.
	pkResp, err := client.PublicKey(ctx, &pb.PublicKeyRequest{})
	if err != nil {
		die("PublicKey RPC: %v", err)
	}
	pkBytes := pkResp.GetPublicKey()
	if *pubkeyHexOnly {
		fmt.Println(hex.EncodeToString(pkBytes))
		return
	}
	pk, err := avabls.PublicKeyFromCompressedBytes(pkBytes)
	if err != nil {
		die("avalanchego rejected the signer's public key: %v", err)
	}
	pass("signer public key is a valid BLS12-381 key: 0x%s", hex.EncodeToString(pkBytes))

	// 2) A warp/message signature verifies under avalanchego (the exact op ICM does).
	msg := []byte("remote-signer e2e — warp/ICM message signing")
	sigResp, err := client.Sign(ctx, &pb.SignRequest{Message: msg})
	if err != nil {
		die("Sign RPC: %v", err)
	}
	sig, err := avabls.SignatureFromBytes(sigResp.GetSignature())
	if err != nil {
		die("avalanchego rejected the signature encoding: %v", err)
	}
	if !avabls.Verify(pk, sig, msg) {
		die("Sign output does NOT verify as an avalanchego message signature — warp/ICM would reject it")
	}
	if avabls.VerifyProofOfPossession(pk, sig, msg) {
		die("Sign output also verifies as a proof of possession — the DSTs are crossed")
	}
	pass("warp message signature verifies under avalanchego bls.Verify (and is NOT a PoP)")

	// 3) A proof of possession (signature over the public key) verifies.
	popResp, err := client.SignProofOfPossession(ctx, &pb.SignProofOfPossessionRequest{Message: pkBytes})
	if err != nil {
		die("SignProofOfPossession RPC: %v", err)
	}
	pop, err := avabls.SignatureFromBytes(popResp.GetSignature())
	if err != nil {
		die("bad proof-of-possession encoding: %v", err)
	}
	if !avabls.VerifyProofOfPossession(pk, pop, pkBytes) {
		die("PoP does NOT verify under avalanchego — validator registration would fail")
	}
	pass("proof of possession verifies under avalanchego bls.VerifyProofOfPossession")

	// 4) The running node is actually using THIS key (proves the node↔signer link).
	if *nodePubHex != "" {
		nodePk := mustHex(*nodePubHex)
		if !bytes.Equal(nodePk, pkBytes) {
			die("node's BLS key (0x%s) != signer key (0x%s) — the node is NOT using the remote signer",
				hex.EncodeToString(nodePk), hex.EncodeToString(pkBytes))
		}
		pass("node's BLS identity (info.getNodeID) matches the remote signer's key")

		if *nodePopHex != "" {
			np, err := avabls.SignatureFromBytes(mustHex(*nodePopHex))
			if err != nil {
				die("bad node proof-of-possession: %v", err)
			}
			if !avabls.VerifyProofOfPossession(pk, np, pkBytes) {
				die("node's proof of possession does not verify against the signer key")
			}
			pass("node's proof of possession (produced via the signer at boot) verifies")
		}
	}

	fmt.Println("\nALL CHECKS PASSED — warp signing works end to end via the remote signer.")
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil {
		die("not valid hex %q: %v", s, err)
	}
	return b
}

func pass(format string, a ...any) { fmt.Printf("PASS  "+format+"\n", a...) }

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "FAIL  "+format+"\n", a...)
	os.Exit(1)
}
