// pchain-cli provides command-line utilities for Avalanche P-Chain operations.
//
// This tool can be used standalone for P-Chain wallet operations, subnet creation,
// and node management. It is also used as a library by create-l1.
package main

import (
	"github.com/ava-labs/avalanche-deploy/tools/pchain-cli/cmd"
)

func main() {
	cmd.Execute()
}
