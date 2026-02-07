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

pod_selector="app.kubernetes.io/instance=$RELEASE"

get_pods() {
    kubectl get pods -l "$pod_selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true
}

check_bootstrap() {
    local pod="$1"
    local ready_status
    ready_status="$(kubectl get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "$ready_status" == "True" ]]
}

start_time="$(date +%s)"
while true; do
    all_synced=true
    pods="$(get_pods)"

    if [[ -z "$pods" ]]; then
        echo "  No pods found for release: $RELEASE"
        all_synced=false
    fi

    for pod in $pods; do
        pod_phase="$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        pod_node="$(kubectl get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
        if [[ -z "$pod_node" ]]; then
            scheduled_msg="$(kubectl get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || true)"
            if [[ -n "$scheduled_msg" ]]; then
                echo "  $pod: pending (unscheduled) - $scheduled_msg"
            else
                echo "  $pod: pending (unscheduled)"
            fi
            all_synced=false
            continue
        fi

        if [[ "$pod_phase" != "Running" ]]; then
            echo "  $pod: $pod_phase"
            all_synced=false
            continue
        fi

        container_running_since="$(kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[?(@.name=="avalanchego")].state.running.startedAt}' 2>/dev/null || true)"
        if [[ -z "$container_running_since" ]]; then
            waiting_reason="$(kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[?(@.name=="avalanchego")].state.waiting.reason}' 2>/dev/null || true)"
            if [[ -n "$waiting_reason" ]]; then
                echo "  $pod: container starting ($waiting_reason)"
            else
                echo "  $pod: container starting"
            fi
            all_synced=false
            continue
        fi

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
