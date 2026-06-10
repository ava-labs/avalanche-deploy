module github.com/ava-labs/avalanche-kms-signer/compat

go 1.25.8

require (
	github.com/ava-labs/avalanche-kms-signer v0.0.0
	github.com/ava-labs/avalanchego v1.14.2
)

require github.com/supranational/blst v0.3.14 // indirect

replace github.com/ava-labs/avalanche-kms-signer => ../
