#!/usr/bin/env bash
# Wait for Avalanche nodes to sync P-Chain.
set -euo pipefail

RELEASE="l1-validators"
TIMEOUT="1800"

usage() {
    cat <<USAGE
Usage: $0 [options]
  --release=NAME         Helm release name (default: l1-validators)
  --timeout=SECONDS      Timeout in seconds (default: 1800)
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release=*) RELEASE="${1#*=}"; shift ;;
        --timeout=*) TIMEOUT="${1#*=}"; shift ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "Waiting for P-Chain sync on release '$RELEASE'..."

PODS="$(kubectl get pods -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[*].metadata.name}')"
if [[ -z "$PODS" ]]; then
    echo "No pods found for release: $RELEASE"
    exit 1
fi

check_bootstrap() {
    local pod="$1"
    local response
    response="$(kubectl exec "$pod" -- curl -s localhost:9650/ext/info \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' || true)"

    [[ "$response" == *'"isBootstrapped":true'* ]]
}

start_time="$(date +%s)"
while true; do
    all_synced=true

    for pod in $PODS; do
        if check_bootstrap "$pod"; then
            echo "  $pod: P-Chain synced"
        else
            echo "  $pod: syncing..."
            all_synced=false
        fi
    done

    if [[ "$all_synced" == "true" ]]; then
        echo ""
        echo "All nodes synced."
        break
    fi

    elapsed="$(( $(date +%s) - start_time ))"
    if [[ "$elapsed" -gt "$TIMEOUT" ]]; then
        echo "Timeout waiting for sync after ${TIMEOUT}s"
        exit 1
    fi

    echo "  Waiting... (${elapsed}s elapsed)"
    sleep 10
done
