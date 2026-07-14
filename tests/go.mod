module github.com/ava-labs/avalanche-remote-signer/tests

go 1.25.12

require (
	github.com/ava-labs/avalanche-remote-signer v0.0.0
	github.com/ava-labs/avalanchego v1.14.2
	google.golang.org/grpc v1.82.0
)

require (
	github.com/supranational/blst v0.3.16 // indirect
	golang.org/x/net v0.57.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.40.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260713224248-f5fc221cf8c4 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)

replace github.com/ava-labs/avalanche-remote-signer => ../
