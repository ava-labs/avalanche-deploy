// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package vault

import (
	"testing"
	"time"
)

// The renewal loop's behavior hinges on classifying the token correctly:
// misreading a batch token as "skip renewal" wedges signing at TTL expiry,
// and misreading a static token as refreshable hot-spins re-auth forever.
func TestClassifyToken(t *testing.T) {
	hour := time.Hour
	tests := []struct {
		name       string
		ttl        time.Duration
		renewable  bool
		authMethod string
		want       tokenAction
	}{
		{"root token never expires", 0, false, "token", tokenActionNone},
		{"root token via kubernetes", 0, false, "kubernetes", tokenActionNone},
		{"renewable static token", hour, true, "token", tokenActionRenew},
		{"renewable k8s token", hour, true, "kubernetes", tokenActionRenew},
		{"renewable with empty auth method", hour, true, "", tokenActionRenew},
		// Batch tokens: renewable=false, ttl>0, dynamic auth — must re-login,
		// not exit (the pre-fix behavior wedged signing at TTL expiry).
		{"batch token via kubernetes", hour, false, "kubernetes", tokenActionReauth},
		{"batch token via aws-iam", hour, false, "aws-iam", tokenActionReauth},
		// A static non-renewable expiring token can't be refreshed — re-login
		// would re-install the same token. Warn and stop.
		{"non-renewable static token", hour, false, "token", tokenActionStop},
		{"non-renewable static token, empty auth method", hour, false, "", tokenActionStop},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := classifyToken(tt.ttl, tt.renewable, tt.authMethod); got != tt.want {
				t.Fatalf("classifyToken(%v, %v, %q) = %d, want %d",
					tt.ttl, tt.renewable, tt.authMethod, got, tt.want)
			}
		})
	}
}
