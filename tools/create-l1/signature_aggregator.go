package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/ava-labs/avalanchego/ids"
)

// SignatureAggregatorConfig is the configuration for the signature-aggregator service
type SignatureAggregatorConfig struct {
	LogLevel             string       `json:"log-level"`
	PChainAPI            APIConfig    `json:"p-chain-api"`
	InfoAPI              APIConfig    `json:"info-api"`
	APIPort              uint16       `json:"api-port"`
	MetricsPort          uint16       `json:"metrics-port"`
	AllowPrivateIPs      bool         `json:"allow-private-ips"`
	TrackedSubnetIDs     []string     `json:"tracked-subnet-ids"`
	ManuallyTrackedPeers []PeerConfig `json:"manually-tracked-peers"`
	SignatureCacheSize   uint64       `json:"signature-cache-size"`
}

// APIConfig represents an API endpoint configuration
type APIConfig struct {
	BaseURL string `json:"base-url"`
}

// PeerConfig represents a manually tracked peer
type PeerConfig struct {
	ID string `json:"id"`
	IP string `json:"ip"`
}

// SignatureAggregator manages a local signature-aggregator instance
type SignatureAggregator struct {
	config     *SignatureAggregatorConfig
	configPath string
	binaryPath string
	process    *exec.Cmd
	port       uint16
}

// SignatureAggregatorRequest is the request body for /aggregate-signatures
type SignatureAggregatorRequest struct {
	Message                string `json:"message"`
	Justification          string `json:"justification,omitempty"`
	SigningSubnetID        string `json:"signing-subnet-id,omitempty"`
	QuorumPercentage       int    `json:"quorum-percentage,omitempty"`
	QuorumPercentageBuffer int    `json:"quorum-percentage-buffer,omitempty"`
	PChainHeight           int64  `json:"p-chain-height,omitempty"`
}

// SignatureAggregatorResponse is the response from /aggregate-signatures
type SignatureAggregatorResponse struct {
	SignedMessage string `json:"signed-message"`
	Error         string `json:"error,omitempty"`
}

// NewSignatureAggregator creates a new SignatureAggregator instance
func NewSignatureAggregator(
	nodeURIs []string,
	nodeIDs []ids.NodeID,
	subnetID ids.ID,
	pChainAPI string,
	port uint16,
) *SignatureAggregator {
	if port == 0 {
		port = 8080
	}

	// Build peer configs
	peers := make([]PeerConfig, len(nodeIDs))
	for i, nodeID := range nodeIDs {
		// Extract IP from URI (http://IP:9650 -> IP:9651 for staking port)
		uri := nodeURIs[i]
		uri = strings.TrimPrefix(uri, "http://")
		uri = strings.TrimPrefix(uri, "https://")
		parts := strings.Split(uri, ":")
		ip := parts[0]
		// Staking port is typically 9651
		peers[i] = PeerConfig{
			ID: nodeID.String(),
			IP: fmt.Sprintf("%s:9651", ip),
		}
	}

	config := &SignatureAggregatorConfig{
		LogLevel: "info",
		PChainAPI: APIConfig{
			BaseURL: pChainAPI,
		},
		InfoAPI: APIConfig{
			BaseURL: pChainAPI,
		},
		APIPort:              port,
		MetricsPort:          port + 1,
		AllowPrivateIPs:      true,
		TrackedSubnetIDs:     []string{subnetID.String()},
		ManuallyTrackedPeers: peers,
		SignatureCacheSize:   1024 * 1024, // 1MB
	}

	return &SignatureAggregator{
		config: config,
		port:   port,
	}
}

// GenerateConfig creates the config file for the signature-aggregator
func (sa *SignatureAggregator) GenerateConfig(outputDir string) (string, error) {
	configPath := filepath.Join(outputDir, "signature-aggregator-config.json")

	data, err := json.MarshalIndent(sa.config, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal config: %w", err)
	}

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return "", fmt.Errorf("failed to create config directory: %w", err)
	}

	if err := os.WriteFile(configPath, data, 0644); err != nil {
		return "", fmt.Errorf("failed to write config: %w", err)
	}

	sa.configPath = configPath
	return configPath, nil
}

// FindBinary locates the signature-aggregator binary
func (sa *SignatureAggregator) FindBinary(icmServicesPath string) (string, error) {
	// Check common locations
	paths := []string{
		filepath.Join(icmServicesPath, "signature-aggregator", "build", "signature-aggregator"),
		filepath.Join(icmServicesPath, "build", "signature-aggregator"),
		"signature-aggregator",
	}

	// Also check PATH
	if p, err := exec.LookPath("signature-aggregator"); err == nil {
		paths = append([]string{p}, paths...)
	}

	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			sa.binaryPath = p
			return p, nil
		}
	}

	return "", fmt.Errorf("signature-aggregator binary not found. Build it with: cd %s && ./scripts/build_signature_aggregator.sh", icmServicesPath)
}

// Start starts the signature-aggregator process
func (sa *SignatureAggregator) Start(ctx context.Context) error {
	if sa.binaryPath == "" {
		return fmt.Errorf("binary path not set - call FindBinary first")
	}
	if sa.configPath == "" {
		return fmt.Errorf("config path not set - call GenerateConfig first")
	}

	sa.process = exec.CommandContext(ctx, sa.binaryPath, "--config-file", sa.configPath)
	sa.process.Stdout = os.Stdout
	sa.process.Stderr = os.Stderr

	if err := sa.process.Start(); err != nil {
		return fmt.Errorf("failed to start signature-aggregator: %w", err)
	}

	// Wait for the service to be ready
	return sa.waitForReady(ctx, 30*time.Second)
}

// Stop stops the signature-aggregator process
func (sa *SignatureAggregator) Stop() error {
	if sa.process != nil && sa.process.Process != nil {
		return sa.process.Process.Kill()
	}
	return nil
}

// waitForReady waits for the signature-aggregator to be ready
func (sa *SignatureAggregator) waitForReady(ctx context.Context, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	url := fmt.Sprintf("http://localhost:%d/health", sa.port)

	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}

	return fmt.Errorf("signature-aggregator not ready after %v", timeout)
}

// GetURL returns the URL for the signature-aggregator API
func (sa *SignatureAggregator) GetURL() string {
	return fmt.Sprintf("http://localhost:%d", sa.port)
}

// AggregateSignatures calls the local signature-aggregator to get aggregated signatures
func (sa *SignatureAggregator) AggregateSignatures(
	ctx context.Context,
	unsignedMessage []byte,
	justification []byte,
	signingSubnetID ids.ID,
	quorumPercentage int,
) ([]byte, error) {
	if quorumPercentage == 0 {
		quorumPercentage = 67
	}

	req := SignatureAggregatorRequest{
		Message:          hex.EncodeToString(unsignedMessage),
		QuorumPercentage: quorumPercentage,
	}

	if len(justification) > 0 {
		req.Justification = hex.EncodeToString(justification)
	}

	if signingSubnetID != ids.Empty {
		req.SigningSubnetID = signingSubnetID.String()
	}

	reqBody, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	url := fmt.Sprintf("%s/aggregate-signatures", sa.GetURL())
	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("failed to call signature-aggregator: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var result SignatureAggregatorResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w (body: %s)", err, string(body))
	}

	if result.Error != "" {
		return nil, fmt.Errorf("signature aggregation failed: %s", result.Error)
	}

	if result.SignedMessage == "" {
		return nil, fmt.Errorf("empty signed message in response")
	}

	// Decode the hex-encoded signed message
	signedMessage := strings.TrimPrefix(result.SignedMessage, "0x")
	return hex.DecodeString(signedMessage)
}

// AggregateSignaturesWithRetry calls AggregateSignatures with retries
func (sa *SignatureAggregator) AggregateSignaturesWithRetry(
	ctx context.Context,
	unsignedMessage []byte,
	justification []byte,
	signingSubnetID ids.ID,
	quorumPercentage int,
	maxRetries int,
) ([]byte, error) {
	var lastErr error

	for i := 0; i < maxRetries; i++ {
		sig, err := sa.AggregateSignatures(ctx, unsignedMessage, justification, signingSubnetID, quorumPercentage)
		if err == nil {
			return sig, nil
		}
		lastErr = err

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		if i < maxRetries-1 {
			fmt.Printf("    Retry %d/%d: %v\n", i+1, maxRetries, err)
			time.Sleep(5 * time.Second)
		}
	}

	return nil, fmt.Errorf("failed after %d attempts: %w", maxRetries, lastErr)
}

// CallLocalSignatureAggregator is a convenience function to call a running local signature-aggregator
func CallLocalSignatureAggregator(
	ctx context.Context,
	url string,
	unsignedMessage []byte,
	justification []byte,
	signingSubnetID ids.ID,
	quorumPercentage int,
) ([]byte, error) {
	if quorumPercentage == 0 {
		quorumPercentage = 67
	}

	req := SignatureAggregatorRequest{
		Message:          hex.EncodeToString(unsignedMessage),
		QuorumPercentage: quorumPercentage,
	}

	if len(justification) > 0 {
		req.Justification = hex.EncodeToString(justification)
	}

	if signingSubnetID != ids.Empty {
		req.SigningSubnetID = signingSubnetID.String()
	}

	reqBody, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	apiURL := fmt.Sprintf("%s/aggregate-signatures", strings.TrimSuffix(url, "/"))
	httpReq, err := http.NewRequestWithContext(ctx, "POST", apiURL, bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("failed to call signature-aggregator: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var result SignatureAggregatorResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w (body: %s)", err, string(body))
	}

	if result.Error != "" {
		return nil, fmt.Errorf("signature aggregation failed: %s", result.Error)
	}

	signedMessage := strings.TrimPrefix(result.SignedMessage, "0x")
	return hex.DecodeString(signedMessage)
}

// GenerateSignatureAggregatorSystemdService generates a systemd service file
func GenerateSignatureAggregatorSystemdService(
	binaryPath string,
	configPath string,
	user string,
) string {
	return fmt.Sprintf(`[Unit]
Description=Avalanche Signature Aggregator
After=network.target

[Service]
Type=simple
User=%s
ExecStart=%s --config-file %s
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
`, user, binaryPath, configPath)
}

// GenerateSignatureAggregatorDockerCompose generates a docker-compose snippet
func GenerateSignatureAggregatorDockerCompose(
	configPath string,
	port uint16,
) string {
	return fmt.Sprintf(`  signature-aggregator:
    image: avaplatform/signature-aggregator:latest
    ports:
      - "%d:8080"
    volumes:
      - %s:/config/signature-aggregator-config.json:ro
    command: ["--config-file", "/config/signature-aggregator-config.json"]
    restart: unless-stopped
`, port, configPath)
}
