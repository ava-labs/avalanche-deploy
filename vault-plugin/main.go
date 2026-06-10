// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package main

import (
	"os"

	"github.com/hashicorp/vault/sdk/plugin"

	blssigner "github.com/ava-labs/avalanche-remote-signer/vault-plugin/backend"
)

func main() {
	if err := plugin.ServeMultiplex(&plugin.ServeOpts{
		BackendFactoryFunc: blssigner.Factory,
	}); err != nil {
		os.Exit(1)
	}
}
