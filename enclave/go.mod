module github.com/ava-labs/avalanche-kms-signer/enclave

go 1.22

require (
	github.com/aws/aws-sdk-go-v2 v1.30.3
	github.com/aws/aws-sdk-go-v2/config v1.27.27
	github.com/aws/aws-sdk-go-v2/service/kms v1.35.3
	github.com/supranational/blst v0.3.14
	github.com/mdlayher/vsock v1.2.1
	github.com/ava-labs/avalanche-kms-signer v0.0.0
)

replace github.com/ava-labs/avalanche-kms-signer => ../
