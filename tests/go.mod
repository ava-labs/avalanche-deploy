module github.com/ava-labs/avalanche-remote-signer/tests

go 1.25.8

require (
	github.com/ava-labs/avalanche-remote-signer v0.0.0
	github.com/ava-labs/avalanchego v1.14.2
	google.golang.org/grpc v1.79.3
)

require (
	github.com/supranational/blst v0.3.14 // indirect
	golang.org/x/net v0.50.0 // indirect
	golang.org/x/sys v0.41.0 // indirect
	golang.org/x/text v0.34.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20251202230838-ff82c1b0f217 // indirect
	google.golang.org/protobuf v1.36.10 // indirect
)

replace github.com/ava-labs/avalanche-remote-signer => ../
