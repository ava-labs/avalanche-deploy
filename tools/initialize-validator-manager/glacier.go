package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const glacierAPIBaseURL = "https://glacier-api.avax.network"

type httpDoer interface {
	Do(*http.Request) (*http.Response, error)
}

func waitForGlacierSignature(ctx context.Context, network, txHash, apiKey string) ([]byte, error) {
	return fetchGlacierSignature(
		ctx,
		httpClient,
		glacierAPIBaseURL,
		network,
		txHash,
		apiKey,
		30,
		10*time.Second,
	)
}

func fetchGlacierSignature(
	ctx context.Context,
	client httpDoer,
	baseURL string,
	network string,
	txHash string,
	apiKey string,
	maxAttempts int,
	retryDelay time.Duration,
) ([]byte, error) {
	if strings.TrimSpace(apiKey) == "" {
		return nil, fmt.Errorf("GLACIER_API_KEY is required when using the Glacier signature service")
	}
	switch network {
	case "mainnet", "fuji", "testnet":
	default:
		return nil, fmt.Errorf("unsupported Glacier network %q (expected fuji, testnet, or mainnet)", network)
	}
	if strings.TrimSpace(txHash) == "" {
		return nil, fmt.Errorf("conversion transaction hash is required")
	}
	if maxAttempts < 1 {
		return nil, fmt.Errorf("max attempts must be at least 1")
	}

	requestURL := fmt.Sprintf(
		"%s/v1/signatureAggregator/%s/aggregateSignatures/%s",
		strings.TrimRight(baseURL, "/"),
		url.PathEscape(network),
		url.PathEscape(txHash),
	)

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
		if err != nil {
			return nil, fmt.Errorf("create Glacier signature request: %w", err)
		}
		req.Header.Set("x-glacier-api-key", apiKey)

		resp, err := client.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			lastErr = fmt.Errorf("Glacier signature request failed: %w", err)
		} else {
			responseBody, readErr := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			if readErr != nil {
				return nil, fmt.Errorf("read Glacier signature response: %w", readErr)
			}

			if resp.StatusCode >= http.StatusOK && resp.StatusCode < http.StatusMultipleChoices {
				var result struct {
					SignedMessage string `json:"signedMessage"`
				}
				if err := json.Unmarshal(responseBody, &result); err != nil {
					return nil, fmt.Errorf("decode Glacier signature response: %w", err)
				}
				if strings.TrimSpace(result.SignedMessage) != "" {
					signedMessage, err := hex.DecodeString(strings.TrimPrefix(result.SignedMessage, "0x"))
					if err != nil {
						return nil, fmt.Errorf("decode Glacier signedMessage: %w", err)
					}
					return signedMessage, nil
				}
				// Glacier acknowledges the request before aggregation finishes, so
				// an empty signedMessage means "not ready yet": keep waiting inside
				// the retry budget instead of failing the deployment.
				lastErr = fmt.Errorf("Glacier signature response did not include signedMessage")
			} else {
				responseSummary := strings.TrimSpace(string(responseBody))
				if len(responseSummary) > 512 {
					responseSummary = responseSummary[:512] + "..."
				}
				statusErr := fmt.Errorf("Glacier signature request returned HTTP %d", resp.StatusCode)
				if responseSummary != "" {
					statusErr = fmt.Errorf("%w: %s", statusErr, responseSummary)
				}

				// 404 is what Glacier serves for a conversion transaction it has not
				// indexed yet, which is the normal state for the first minutes after
				// the P-Chain accepts it. 400/401/403 stay terminal because waiting
				// never fixes a malformed request or a bad API key.
				if resp.StatusCode != http.StatusNotFound &&
					resp.StatusCode != http.StatusTooManyRequests &&
					resp.StatusCode < http.StatusInternalServerError {
					return nil, statusErr
				}
				lastErr = statusErr
			}
		}

		if attempt == maxAttempts {
			break
		}
		if err := waitForRetry(ctx, retryDelay); err != nil {
			return nil, err
		}
	}

	return nil, fmt.Errorf("failed to obtain Glacier signature after %d attempts: %w", maxAttempts, lastErr)
}

func waitForRetry(ctx context.Context, delay time.Duration) error {
	if delay <= 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

var httpClient = &http.Client{Timeout: 60 * time.Second}
