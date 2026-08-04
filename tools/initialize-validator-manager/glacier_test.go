package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type httpDoerFunc func(*http.Request) (*http.Response, error)

func (f httpDoerFunc) Do(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestFetchGlacierSignatureUsesOfficialRouteHeaderAndCreatedStatus(t *testing.T) {
	const (
		apiKey = "test-api-key"
		txHash = "conversion-tx"
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("method = %s, want GET", r.Method)
		}
		if r.URL.Path != "/v1/signatureAggregator/fuji/aggregateSignatures/"+txHash {
			t.Errorf("path = %s", r.URL.Path)
		}
		if got := r.Header.Get("x-glacier-api-key"); got != apiKey {
			t.Errorf("x-glacier-api-key = %q, want %q", got, apiKey)
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"signedMessage":"0x0102"}`))
	}))
	defer server.Close()

	got, err := fetchGlacierSignature(
		context.Background(),
		server.Client(),
		server.URL,
		"fuji",
		txHash,
		apiKey,
		1,
		0,
	)
	if err != nil {
		t.Fatalf("fetchGlacierSignature returned error: %v", err)
	}
	if !bytes.Equal(got, []byte{1, 2}) {
		t.Fatalf("signed message = %x, want 0102", got)
	}
}

func TestFetchGlacierSignatureRequiresAPIKeyBeforeRequest(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusCreated)
	}))
	defer server.Close()

	_, err := fetchGlacierSignature(
		context.Background(),
		server.Client(),
		server.URL,
		"fuji",
		"tx",
		"",
		3,
		0,
	)
	if err == nil || !strings.Contains(err.Error(), "GLACIER_API_KEY is required") {
		t.Fatalf("got error %v, want missing API key error", err)
	}
	if requests.Load() != 0 {
		t.Fatalf("server received %d requests, want none", requests.Load())
	}
}

func TestFetchGlacierSignatureRetriesOnlyRetryableStatuses(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		switch attempt := requests.Add(1); attempt {
		case 1:
			http.Error(w, "rate limited", http.StatusTooManyRequests)
		case 2:
			http.Error(w, "temporary failure", http.StatusBadGateway)
		default:
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"signedMessage":"03"}`))
		}
	}))
	defer server.Close()

	got, err := fetchGlacierSignature(
		context.Background(),
		server.Client(),
		server.URL,
		"fuji",
		"tx",
		"key",
		5,
		0,
	)
	if err != nil {
		t.Fatalf("fetchGlacierSignature returned error: %v", err)
	}
	if !bytes.Equal(got, []byte{3}) {
		t.Fatalf("signed message = %x, want 03", got)
	}
	if requests.Load() != 3 {
		t.Fatalf("requests = %d, want 3", requests.Load())
	}
}

func TestFetchGlacierSignatureDoesNotRetryTerminal4xx(t *testing.T) {
	for _, status := range []int{
		http.StatusBadRequest,
		http.StatusUnauthorized,
		http.StatusForbidden,
	} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				requests.Add(1)
				http.Error(w, "terminal", status)
			}))
			defer server.Close()

			_, err := fetchGlacierSignature(
				context.Background(),
				server.Client(),
				server.URL,
				"fuji",
				"tx",
				"key",
				5,
				0,
			)
			if err == nil || !strings.Contains(err.Error(), fmt.Sprintf("HTTP %d", status)) {
				t.Fatalf("got error %v, want HTTP %d", err, status)
			}
			if requests.Load() != 1 {
				t.Fatalf("requests = %d, want 1", requests.Load())
			}
		})
	}
}

func TestFetchGlacierSignatureRetriesNetworkFailure(t *testing.T) {
	var requests atomic.Int32
	client := httpDoerFunc(func(*http.Request) (*http.Response, error) {
		if requests.Add(1) == 1 {
			return nil, errors.New("temporary network failure")
		}
		return &http.Response{
			StatusCode: http.StatusCreated,
			Body:       io.NopCloser(strings.NewReader(`{"signedMessage":"04"}`)),
		}, nil
	})

	got, err := fetchGlacierSignature(
		context.Background(),
		client,
		"https://example.invalid",
		"fuji",
		"tx",
		"key",
		3,
		0,
	)
	if err != nil {
		t.Fatalf("fetchGlacierSignature returned error: %v", err)
	}
	if !bytes.Equal(got, []byte{4}) {
		t.Fatalf("signed message = %x, want 04", got)
	}
	if requests.Load() != 2 {
		t.Fatalf("requests = %d, want 2", requests.Load())
	}
}

func TestFetchGlacierSignatureRetriesUntilConversionIsIndexed(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		switch attempt := requests.Add(1); attempt {
		case 1:
			// Glacier has not indexed the accepted conversion transaction yet.
			http.Error(w, "not found", http.StatusNotFound)
		case 2:
			// Indexed, but aggregation has not produced a signature yet.
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{}`))
		default:
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"signedMessage":"05"}`))
		}
	}))
	defer server.Close()

	got, err := fetchGlacierSignature(
		context.Background(),
		server.Client(),
		server.URL,
		"fuji",
		"tx",
		"key",
		5,
		0,
	)
	if err != nil {
		t.Fatalf("fetchGlacierSignature returned error: %v", err)
	}
	if !bytes.Equal(got, []byte{5}) {
		t.Fatalf("signed message = %x, want 05", got)
	}
	if requests.Load() != 3 {
		t.Fatalf("requests = %d, want 3", requests.Load())
	}
}

func TestFetchGlacierSignatureStopsAfterMaxAttempts(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		http.Error(w, "not found", http.StatusNotFound)
	}))
	defer server.Close()

	_, err := fetchGlacierSignature(
		context.Background(),
		server.Client(),
		server.URL,
		"fuji",
		"tx",
		"key",
		3,
		0,
	)
	if err == nil || !strings.Contains(err.Error(), "after 3 attempts") {
		t.Fatalf("got error %v, want an exhausted retry budget", err)
	}
	if requests.Load() != 3 {
		t.Fatalf("requests = %d, want 3", requests.Load())
	}
}
