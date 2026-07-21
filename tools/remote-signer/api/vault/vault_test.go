// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package vault

import "testing"

// The renewal loop's behavior hinges on classifying the token correctly:
// misreading a batch token as "skip renewal" wedges signing at TTL expiry,
// misreading a static token as refreshable hot-spins re-auth forever, and —
// the subtlest — judging "never expires" by ttl==0 instead of the expires
// flag exits the loop permanently for a live token in its final sub-second
// (Vault reports TTL in whole seconds, rounded down).
func TestClassifyToken(t *testing.T) {
	tests := []struct {
		name       string
		expires    bool
		renewable  bool
		authMethod string
		want       tokenAction
	}{
		{"root token never expires", false, false, "token", tokenActionNone},
		{"root token via kubernetes", false, false, "kubernetes", tokenActionNone},
		{"renewable static token", true, true, "token", tokenActionRenew},
		{"renewable k8s token", true, true, "kubernetes", tokenActionRenew},
		{"renewable with empty auth method", true, true, "", tokenActionRenew},
		// Batch tokens: renewable=false but expiring, dynamic auth — must
		// re-login, not exit (the pre-fix behavior wedged signing at expiry).
		{"batch token via kubernetes", true, false, "kubernetes", tokenActionReauth},
		{"batch token via aws-iam", true, false, "aws-iam", tokenActionReauth},
		// A static non-renewable expiring token can't be refreshed — re-login
		// would re-install the same token. Warn and stop.
		{"non-renewable static token", true, false, "token", tokenActionStop},
		{"non-renewable static token, empty auth method", true, false, "", tokenActionStop},
		// The ttl=0 trap: a token that EXPIRES must never classify as None,
		// even when its reported TTL has rounded down to zero — expiry is
		// judged by the expires flag alone. (ttl is not an input here at all;
		// this row pins the renewable case that previously hit `ttl <= 0`.)
		{"expiring renewable token in its final sub-second", true, true, "kubernetes", tokenActionRenew},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := classifyToken(tt.expires, tt.renewable, tt.authMethod); got != tt.want {
				t.Fatalf("classifyToken(expires=%v, renewable=%v, %q) = %d, want %d",
					tt.expires, tt.renewable, tt.authMethod, got, tt.want)
			}
		})
	}
}
