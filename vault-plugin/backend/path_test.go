// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package backend

import (
	"context"
	"encoding/hex"
	"sync"
	"testing"

	"github.com/hashicorp/vault/sdk/logical"
)

// testBackend returns a backend wired to in-memory storage. Logger/System are
// left nil — the SDK discards logs and none of these paths touch System.
func testBackend(t *testing.T) (*backend, logical.Storage) {
	t.Helper()
	storage := &logical.InmemStorage{}
	raw, err := Factory(context.Background(), &logical.BackendConfig{StorageView: storage})
	if err != nil {
		t.Fatalf("Factory: %v", err)
	}
	return raw.(*backend), storage
}

func generate(t *testing.T, b *backend, storage logical.Storage, name string) *logical.Response {
	t.Helper()
	resp, err := b.HandleRequest(context.Background(), &logical.Request{
		Operation: logical.CreateOperation,
		Path:      "keys/" + name + "/generate",
		Storage:   storage,
	})
	if err != nil {
		t.Fatalf("generate %q: %v", name, err)
	}
	return resp
}

// #6 — /sign must reject any DST outside the Avalanche allow-list, so a caller
// holding only /sign can't mint signatures under an arbitrary domain.
func TestSignRejectsDisallowedDST(t *testing.T) {
	b, storage := testBackend(t)
	if resp := generate(t, b, storage, "validator"); resp.IsError() {
		t.Fatalf("generate errored: %v", resp.Error())
	}

	msg := hex.EncodeToString([]byte("hello"))
	sign := func(dst string) *logical.Response {
		data := map[string]interface{}{"message": msg}
		if dst != "" {
			data["dst"] = dst
		}
		resp, err := b.HandleRequest(context.Background(), &logical.Request{
			Operation: logical.UpdateOperation,
			Path:      "keys/validator/sign",
			Storage:   storage,
			Data:      data,
		})
		if err != nil {
			t.Fatalf("sign: %v", err)
		}
		return resp
	}

	// Default (no dst) → Warp DST, allowed.
	if resp := sign(""); resp.IsError() {
		t.Fatalf("default DST rejected: %v", resp.Error())
	}
	// Explicit Warp and PoP DSTs → allowed.
	if resp := sign(dstSign); resp.IsError() {
		t.Fatalf("Warp DST rejected: %v", resp.Error())
	}
	if resp := sign(dstPopProve); resp.IsError() {
		t.Fatalf("PoP DST rejected: %v", resp.Error())
	}
	// Mixed-case allowed DST must still pass (hex is case-insensitive).
	if resp := sign(upperHex(dstSign)); resp.IsError() {
		t.Fatalf("mixed-case Warp DST rejected: %v", resp.Error())
	}
	// An arbitrary domain → rejected.
	foreignDST := hex.EncodeToString([]byte("SOME_OTHER_PROTOCOL_XMD:SHA-256_SSWU_RO_NUL_"))
	if resp := sign(foreignDST); !resp.IsError() {
		t.Fatalf("expected foreign DST to be rejected, got signature %v", resp.Data)
	}
}

// #12 — concurrent generate calls for the same key must not clobber each other:
// exactly one succeeds and the stored key is left consistent. Run with -race to
// catch the check-then-write data race the per-key lock closes.
func TestGenerateSerializedUnderConcurrency(t *testing.T) {
	b, storage := testBackend(t)

	const n = 16
	var wg sync.WaitGroup
	var mu sync.Mutex
	var okCount int
	var winnerPub string

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := b.HandleRequest(context.Background(), &logical.Request{
				Operation: logical.CreateOperation,
				Path:      "keys/validator/generate",
				Storage:   storage,
			})
			if err != nil {
				t.Errorf("generate: %v", err)
				return
			}
			if resp.IsError() {
				return // lost the race: "key already exists"
			}
			mu.Lock()
			okCount++
			winnerPub = resp.Data["public_key"].(string)
			mu.Unlock()
		}()
	}
	wg.Wait()

	if okCount != 1 {
		t.Fatalf("expected exactly one generate to succeed, got %d", okCount)
	}

	// The stored key must be the one the sole winner reported.
	resp, err := b.HandleRequest(context.Background(), &logical.Request{
		Operation: logical.ReadOperation,
		Path:      "keys/validator/public-key",
		Storage:   storage,
	})
	if err != nil {
		t.Fatalf("public-key: %v", err)
	}
	if got := resp.Data["public_key"].(string); got != winnerPub {
		t.Fatalf("stored key %q != winner %q — a racing writer clobbered it", got, winnerPub)
	}
}

func upperHex(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'f' {
			b[i] = c - ('a' - 'A')
		}
	}
	return string(b)
}
