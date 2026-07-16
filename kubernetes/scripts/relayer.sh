#!/usr/bin/env bash
# Zero-input Kubernetes installation and lifecycle for the Avalanche L1 Relayer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$K8S_DIR")"

ACTION="${1:-install}"
RELAYER_VERSION="${RELAYER_VERSION:-v0.1.0}"
RELAYER_REPOSITORY="anishnar/Relayer"
RELAYER_RELEASE="relayer"
RELAYER_SECRET="relayer-runtime"
RELAYER_POD="relayer-0"
LOCAL_CONSOLE_PORT="3080"
LOCAL_RPC_PORT="9652"
TIMEOUT="${RELAYER_TIMEOUT:-15m}"

NAMESPACE=""
CONTEXT=""
L1_ENV=""
RPC_SERVICE=""
RPC_RELEASE=""
VALIDATOR_RELEASE=""
OPERATOR_IDENTITY=""
PF_PID=""
TMP_DIR=""
BACKUP_REPLICAS=""

usage() {
    cat <<USAGE
Usage: $0 {install|access|status|logs|backup|upgrade|remove}

The current kube context, namespace, Avalanche Deploy releases, L1 metadata,
RPC endpoint, validator peers, manager contracts, and optional Safe services
are discovered automatically. RELAYER_VERSION is the only advanced override.
USAGE
}

die() {
    echo "Error: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$PF_PID" ]]; then
        kill "$PF_PID" >/dev/null 2>&1 || true
        wait "$PF_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    if [[ -n "$BACKUP_REPLICAS" && -n "$NAMESPACE" ]]; then
        kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas="$BACKUP_REPLICAS" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
    done
}

discover_namespace() {
    CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
    [[ -n "$CONTEXT" ]] || die "no current Kubernetes context; configure kubectl before running this command"

    local configmaps count
    if ! configmaps="$(kubectl get configmaps --all-namespaces -o json 2>/dev/null)"; then
        die "cannot list ConfigMaps in the current context; grant discovery access and retry"
    fi
    count="$(jq '[.items[] | select(.metadata.name == "l1-config")] | length' <<<"$configmaps")"
    if [[ "$count" -eq 0 ]]; then
        die "no Avalanche Deploy l1-config ConfigMap found; run make k8s-l1-configure first"
    fi
    if [[ "$count" -ne 1 ]]; then
        die "found $count l1-config ConfigMaps in context '$CONTEXT'; use a kube context containing exactly one Avalanche Deploy L1"
    fi
    NAMESPACE="$(jq -r '.items[] | select(.metadata.name == "l1-config") | .metadata.namespace' <<<"$configmaps")"
}

discover_l1_env() {
    local candidate resolved existing=""
    # The repository-root artifact is authoritative. The Kubernetes-local path
    # remains a compatibility fallback for older Makefile invocations.
    if [[ -f "$ROOT_DIR/l1.env" ]]; then
        L1_ENV="$ROOT_DIR/l1.env"
        return 0
    fi
    for candidate in "$PWD/l1.env" "$K8S_DIR/l1.env"; do
        [[ -f "$candidate" ]] || continue
        resolved="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
        case ":$existing:" in
            *":$resolved:"*) ;;
            *) existing="${existing:+$existing:}$resolved" ;;
        esac
    done
    if [[ "$existing" == *:* ]]; then
        die "multiple generated l1.env files were found ($existing); remove the stale workspace artifact"
    fi
    L1_ENV="$existing"
    [[ -n "$L1_ENV" ]] || die "generated l1.env not found in the workspace; restore the Avalanche Deploy L1 artifact"
}

env_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$L1_ENV"
}

config_value() {
    kubectl -n "$NAMESPACE" get configmap l1-config -o json | jq -r --arg key "$1" '.data[$key] // empty'
}

resolve_metadata() {
    local key="$1" required="${2:-true}" from_env from_config
    from_env="$(env_value "$key")"
    from_config="$(config_value "$key")"
    if [[ -n "$from_env" && -n "$from_config" && "$from_env" != "$from_config" ]]; then
        die "$key differs between $L1_ENV and $NAMESPACE/l1-config; rerun make k8s-l1-configure"
    fi
    if [[ -n "$from_env" ]]; then
        printf '%s\n' "$from_env"
    elif [[ -n "$from_config" ]]; then
        printf '%s\n' "$from_config"
    elif [[ "$required" == "true" ]]; then
        die "$key is missing from both $L1_ENV and $NAMESPACE/l1-config; restore or regenerate L1 metadata"
    fi
}

discover_workloads() {
    local services statefulsets service_count validator_count
    services="$(kubectl -n "$NAMESPACE" get services \
        -l app.kubernetes.io/name=l1-rpc -o json)"
    service_count="$(jq '.items | length' <<<"$services")"
    [[ "$service_count" -eq 1 ]] || die "expected exactly one l1-rpc Service in namespace '$NAMESPACE', found $service_count"
    RPC_SERVICE="$(jq -r '.items[0].metadata.name' <<<"$services")"
    RPC_RELEASE="$(jq -r '.items[0].metadata.labels["app.kubernetes.io/instance"] // empty' <<<"$services")"
    [[ -n "$RPC_RELEASE" ]] || die "RPC Service '$RPC_SERVICE' lacks the standard app.kubernetes.io/instance label"

    statefulsets="$(kubectl -n "$NAMESPACE" get statefulsets \
        -l app.kubernetes.io/name=l1-validator -o json)"
    validator_count="$(jq '.items | length' <<<"$statefulsets")"
    [[ "$validator_count" -eq 1 ]] || die "expected exactly one l1-validator StatefulSet in namespace '$NAMESPACE', found $validator_count"
    VALIDATOR_RELEASE="$(jq -r '.items[0].metadata.labels["app.kubernetes.io/instance"] // empty' <<<"$statefulsets")"
    [[ -n "$VALIDATOR_RELEASE" ]] || die "validator StatefulSet lacks the standard app.kubernetes.io/instance label"

    local configured_rpc configured_validators
    configured_rpc="$(config_value RPC_RELEASE)"
    configured_validators="$(config_value VALIDATOR_RELEASE)"
    [[ -z "$configured_rpc" || "$configured_rpc" == "$RPC_RELEASE" ]] || \
        die "l1-config RPC_RELEASE '$configured_rpc' does not match discovered release '$RPC_RELEASE'"
    [[ -z "$configured_validators" || "$configured_validators" == "$VALIDATOR_RELEASE" ]] || \
        die "l1-config VALIDATOR_RELEASE '$configured_validators' does not match discovered release '$VALIDATOR_RELEASE'"
}

discover_operator() {
    local whoami
    if ! whoami="$(kubectl auth whoami -o json 2>/dev/null)"; then
        die "kubectl auth whoami failed; use a kubectl version and identity that support SelfSubjectReview"
    fi
    OPERATOR_IDENTITY="$(jq -r '.status.userInfo.username // empty' <<<"$whoami")"
    [[ -n "$OPERATOR_IDENTITY" ]] || die "the current Kubernetes username could not be discovered"
}

start_rpc_forward() {
    local port="${1:-$((21000 + RANDOM % 15000))}"
    kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 \
        "service/$RPC_SERVICE" "${port}:9650" >/dev/null 2>&1 &
    PF_PID=$!
    for _ in $(seq 1 60); do
        if curl --noproxy '*' -fsS "http://127.0.0.1:${port}/ext/info" \
            -X POST -H 'content-type:application/json' \
            -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' >/dev/null 2>&1; then
            RPC_PORT="$port"
            return 0
        fi
        kill -0 "$PF_PID" >/dev/null 2>&1 || break
        sleep 0.25
    done
    die "RPC Service '$RPC_SERVICE' did not become reachable through port-forward"
}

rpc_call() {
    local endpoint="$1" method="$2" params="$3" response
    response="$(curl --noproxy '*' -fsS "http://127.0.0.1:${RPC_PORT}${endpoint}" \
        -X POST -H 'content-type:application/json' \
        -d "$(jq -cn --arg method "$method" --argjson params "$params" \
            '{jsonrpc:"2.0",id:1,method:$method,params:$params}')")" || \
        die "RPC call $method failed through Service '$RPC_SERVICE'"
    if jq -e '.error != null' >/dev/null <<<"$response"; then
        die "RPC call $method returned: $(jq -c '.error' <<<"$response")"
    fi
    printf '%s\n' "$response"
}

evm_call() {
    rpc_call "/ext/bc/$CHAIN_ID/rpc" "$1" "$2"
}

contract_call() {
    local address="$1" selector="$2"
    evm_call eth_call "$(jq -cn --arg to "$address" --arg data "$selector" '[{to:$to,data:$data},"latest"]')" | \
        jq -r '.result // empty'
}

discover_validator_peers() {
    local pods pod_count pod pod_ip port pid response node_id peers_response
    pods="$(kubectl -n "$NAMESPACE" get pods \
        -l "app.kubernetes.io/name=l1-validator,app.kubernetes.io/instance=$VALIDATOR_RELEASE" \
        --field-selector=status.phase=Running -o json | jq -r '.items | sort_by(.metadata.name)[] | .metadata.name')"
    [[ -n "$pods" ]] || die "no running validator pods were found for release '$VALIDATOR_RELEASE'"

    VALIDATOR_PEERS_JSON='[]'
    VALIDATOR_PEERS_CSV=""
    peers_response="$(rpc_call /ext/info info.peers '{}')"
    pod_count=0
    for pod in $pods; do
        pod_count=$((pod_count + 1))
        pod_ip="$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.podIP}')"
        [[ -n "$pod_ip" ]] || die "validator pod '$pod' has no pod IP"
        port="$((36000 + RANDOM % 2000))"
        kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 "pod/$pod" "${port}:9650" >/dev/null 2>&1 &
        pid=$!
        response=""
        for _ in $(seq 1 40); do
            response="$(curl --noproxy '*' -fsS "http://127.0.0.1:${port}/ext/info" \
                -X POST -H 'content-type:application/json' \
                -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' 2>/dev/null || true)"
            [[ -n "$response" ]] && break
            sleep 0.25
        done
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
        node_id="$(jq -r '.result.nodeID // empty' <<<"$response")"
        [[ -n "$node_id" ]] || die "could not read the NodeID from validator pod '$pod'"
        if ! jq -e --arg node "$node_id" '.result.peers // [] | any(.nodeID == $node)' >/dev/null <<<"$peers_response"; then
            die "RPC node '$RPC_SERVICE' cannot see validator peer '$node_id'; rerun make k8s-l1-configure and wait for peering"
        fi
        VALIDATOR_PEERS_JSON="$(jq -cn --argjson peers "$VALIDATOR_PEERS_JSON" \
            --arg node "$node_id" --arg ip "$pod_ip:9651" '$peers + [{nodeId:$node,ip:$ip}]')"
        VALIDATOR_PEERS_CSV="${VALIDATOR_PEERS_CSV:+$VALIDATOR_PEERS_CSV,}$node_id@$pod_ip:9651"
    done
    [[ "$pod_count" -gt 0 ]] || die "no validator peers were discovered"
}

preflight() {
    SUBNET_ID="$(resolve_metadata SUBNET_ID)"
    CHAIN_ID="$(resolve_metadata CHAIN_ID)"
    EVM_CHAIN_ID="$(resolve_metadata EVM_CHAIN_ID)"
    CHAIN_NAME="$(resolve_metadata CHAIN_NAME)"
    NETWORK="$(resolve_metadata NETWORK)"
    POA_MANAGER="$(resolve_metadata POA_MANAGER)"
    VALIDATOR_MANAGER_PROXY="$(resolve_metadata VALIDATOR_MANAGER_PROXY)"
    COIN_NAME="$(resolve_metadata COIN_NAME false)"

    [[ "$NETWORK" == "fuji" || "$NETWORK" == "mainnet" ]] || \
        die "unsupported NETWORK '$NETWORK'; Relayer v1 supports Fuji and Mainnet"
    [[ "$EVM_CHAIN_ID" =~ ^[1-9][0-9]*$ ]] || die "EVM_CHAIN_ID '$EVM_CHAIN_ID' is not a positive integer"
    [[ "$POA_MANAGER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "POA_MANAGER is not a valid EVM address"
    [[ "$VALIDATOR_MANAGER_PROXY" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "VALIDATOR_MANAGER_PROXY is not a valid EVM address"
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"$POA_MANAGER")" != "$(tr '[:upper:]' '[:lower:]' <<<"$VALIDATOR_MANAGER_PROXY")" ]] || \
        die "POA_MANAGER and VALIDATOR_MANAGER_PROXY must differ; bare ValidatorManager deployments are unsupported"

    start_rpc_forward
    local expected_network reported_network pchain_validators blockchains chain_subnet chain_name_on_pchain bootstrapped reported_chain manager_code manager_code_lower vm_code vm_owner initialized owner_word owner_code threshold
    expected_network=5
    [[ "$NETWORK" == "mainnet" ]] && expected_network=1
    reported_network="$(rpc_call /ext/info info.getNetworkID '{}' | jq -r '.result.networkID // empty')"
    [[ "$reported_network" == "$expected_network" ]] || \
        die "RPC network ID '$reported_network' does not match $NETWORK ($expected_network)"
    pchain_validators="$(rpc_call /ext/P platform.getCurrentValidators \
        "$(jq -cn --arg subnet "$SUBNET_ID" '{subnetID:$subnet}')")"
    [[ "$(jq '.result.validators // [] | length' <<<"$pchain_validators")" -gt 0 ]] || \
        die "P-Chain does not report validators for discovered SUBNET_ID '$SUBNET_ID'"
    blockchains="$(rpc_call /ext/P platform.getBlockchains '{}')"
    chain_subnet="$(jq -r --arg chain "$CHAIN_ID" \
        '.result.blockchains // [] | map(select(.id == $chain)) | if length == 1 then .[0].subnetID else empty end' <<<"$blockchains")"
    chain_name_on_pchain="$(jq -r --arg chain "$CHAIN_ID" \
        '.result.blockchains // [] | map(select(.id == $chain)) | if length == 1 then .[0].name else empty end' <<<"$blockchains")"
    [[ "$chain_subnet" == "$SUBNET_ID" ]] || \
        die "blockchain '$CHAIN_ID' is not registered to discovered SUBNET_ID '$SUBNET_ID'"
    [[ "$chain_name_on_pchain" == "$CHAIN_NAME" ]] || \
        die "P-Chain name '$chain_name_on_pchain' for blockchain '$CHAIN_ID' does not match CHAIN_NAME '$CHAIN_NAME'"
    bootstrapped="$(rpc_call /ext/info info.isBootstrapped "$(jq -cn --arg chain "$CHAIN_ID" '{chain:$chain}')" | jq -r '.result.isBootstrapped // false')"
    [[ "$bootstrapped" == "true" ]] || die "blockchain '$CHAIN_ID' is not bootstrapped on RPC Service '$RPC_SERVICE'"

    reported_chain="$(evm_call eth_chainId '[]' | jq -r '.result // empty')"
    [[ -n "$reported_chain" && "$((reported_chain))" -eq "$EVM_CHAIN_ID" ]] || \
        die "RPC EVM chain ID '$reported_chain' does not match EVM_CHAIN_ID '$EVM_CHAIN_ID'"

    manager_code="$(evm_call eth_getCode "$(jq -cn --arg address "$POA_MANAGER" '[$address,"latest"]')" | jq -r '.result // empty')"
    vm_code="$(evm_call eth_getCode "$(jq -cn --arg address "$VALIDATOR_MANAGER_PROXY" '[$address,"latest"]')" | jq -r '.result // empty')"
    [[ -n "$manager_code" && "$manager_code" != "0x" && "$manager_code" != "0x0" ]] || die "no contract exists at POA_MANAGER $POA_MANAGER"
    manager_code_lower="$(tr '[:upper:]' '[:lower:]' <<<"$manager_code")"
    [[ "$manager_code_lower" == *89f9f85b* ]] || \
        die "POA_MANAGER $POA_MANAGER is not the official PoAManager; bare managers and custom wrappers are unsupported"
    [[ -n "$vm_code" && "$vm_code" != "0x" && "$vm_code" != "0x0" ]] || die "no contract exists at VALIDATOR_MANAGER_PROXY $VALIDATOR_MANAGER_PROXY"

    vm_owner="$(contract_call "$VALIDATOR_MANAGER_PROXY" 0x8da5cb5b)"
    [[ "$vm_owner" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "ValidatorManager owner() is incompatible with the official contract"
    vm_owner="0x${vm_owner: -40}"
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"$vm_owner")" == "$(tr '[:upper:]' '[:lower:]' <<<"$POA_MANAGER")" ]] || \
        die "ValidatorManager owner is $vm_owner, expected official PoAManager $POA_MANAGER"
    initialized="$(contract_call "$VALIDATOR_MANAGER_PROXY" 0x5bd93e88)"
    [[ "$initialized" =~ 1$ ]] || die "ValidatorManager validator set is not initialized"

    owner_word="$(contract_call "$POA_MANAGER" 0x8da5cb5b)"
    [[ "$owner_word" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "PoAManager owner() is incompatible with the official contract"
    POA_OWNER="0x${owner_word: -40}"
    owner_code="$(evm_call eth_getCode "$(jq -cn --arg address "$POA_OWNER" '[$address,"latest"]')" | jq -r '.result // empty')"
    OWNER_TYPE="EOA"
    if [[ -n "$owner_code" && "$owner_code" != "0x" && "$owner_code" != "0x0" ]]; then
        threshold="$(contract_call "$POA_OWNER" 0xe75235b8)"
        [[ "$threshold" =~ ^0x[0-9a-fA-F]{64}$ && "$((threshold))" -gt 0 ]] || \
            die "PoAManager owner $POA_OWNER is a contract but not a compatible Safe; custom owner wrappers are unsupported"
        OWNER_TYPE="Safe"
    fi

    discover_validator_peers
}

discover_safe() {
    SAFE_ENABLED=false
    SAFE_RELEASE=""
    SAFE_TXS_SERVICE=""
    SAFE_UI_SERVICE=""
    [[ "$OWNER_TYPE" == "Safe" ]] || return 0

    local releases count services
    releases="$(helm list -n "$NAMESPACE" -o json)"
    count="$(jq '[.[] | select((.chart // "") | startswith("safe-"))] | length' <<<"$releases")"
    if [[ "$count" -gt 1 ]]; then
        die "multiple Avalanche Deploy Safe Helm releases were found in namespace '$NAMESPACE'"
    fi
    [[ "$count" -eq 1 ]] || return 0
    SAFE_RELEASE="$(jq -r '.[] | select((.chart // "") | startswith("safe-")) | .name' <<<"$releases")"
    services="$(kubectl -n "$NAMESPACE" get services \
        -l "app.kubernetes.io/name=safe-txs,app.kubernetes.io/instance=$SAFE_RELEASE" -o json)"
    [[ "$(jq '.items | length' <<<"$services")" -eq 1 ]] || \
        die "Safe release '$SAFE_RELEASE' has no unique safe-txs Service"
    SAFE_TXS_SERVICE="$(jq -r '.items[0].metadata.name' <<<"$services")"
    SAFE_UI_SERVICE="$(kubectl -n "$NAMESPACE" get services \
        -l "app.kubernetes.io/name=safe-ui,app.kubernetes.io/instance=$SAFE_RELEASE" \
        -o json | jq -r '.items | if length == 1 then .[0].metadata.name else empty end')"
    SAFE_ENABLED=true
}

download_setup() {
    [[ "$RELAYER_VERSION" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || \
        die "RELAYER_VERSION must be a version tag beginning with v (found: $RELAYER_VERSION)"
    local os arch version asset base expected actual extracted
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$os" in darwin|linux) ;; *) die "unsupported setup host OS: $os" ;; esac
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        arm64|aarch64) arch=arm64 ;;
        *) die "unsupported setup host architecture: $(uname -m)" ;;
    esac
    version="${RELAYER_VERSION#v}"
    asset="relayer_${version}_${os}_${arch}.tar.gz"
    base="https://github.com/$RELAYER_REPOSITORY/releases/download/$RELAYER_VERSION"
    TMP_DIR="$(mktemp -d)"
    curl -fL --retry 3 -o "$TMP_DIR/$asset" "$base/$asset" || die "failed to download Relayer release asset $asset"
    curl -fL --retry 3 -o "$TMP_DIR/checksums.txt" "$base/checksums.txt" || die "failed to download Relayer release checksums"
    expected="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset {print $1; exit}' "$TMP_DIR/checksums.txt")"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "checksums.txt has no checksum for $asset"
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$TMP_DIR/$asset" | awk '{print $1}')"
    else
        actual="$(shasum -a 256 "$TMP_DIR/$asset" | awk '{print $1}')"
    fi
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"$actual")" == "$(tr '[:upper:]' '[:lower:]' <<<"$expected")" ]] || die "checksum mismatch for $asset"
    mkdir "$TMP_DIR/release"
    tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR/release"
    extracted="$(find "$TMP_DIR/release" -type f -name relayer-setup -perm -u+x -print -quit)"
    [[ -n "$extracted" ]] || die "release archive does not contain an executable relayer-setup"
    SETUP_BIN="$extracted"
}

persist_l1_metadata() {
    local patch
    kubectl -n "$NAMESPACE" label configmap l1-config --overwrite \
        app.kubernetes.io/name=l1-config \
        app.kubernetes.io/instance="$VALIDATOR_RELEASE" \
        app.kubernetes.io/component=l1-metadata \
        app.kubernetes.io/part-of=avalanche-deploy >/dev/null
    patch="$(jq -cn \
        --arg subnet "$SUBNET_ID" --arg chain "$CHAIN_ID" --arg evm "$EVM_CHAIN_ID" \
        --arg chainName "$CHAIN_NAME" --arg network "$NETWORK" --arg poa "$POA_MANAGER" \
        --arg vm "$VALIDATOR_MANAGER_PROXY" --arg peers "$VALIDATOR_PEERS_CSV" \
        --arg rpcRelease "$RPC_RELEASE" --arg validatorRelease "$VALIDATOR_RELEASE" \
        --arg relayerVersion "$RELAYER_VERSION" \
        '{data:{SUBNET_ID:$subnet,CHAIN_ID:$chain,EVM_CHAIN_ID:$evm,CHAIN_NAME:$chainName,
          NETWORK:$network,POA_MANAGER:$poa,VALIDATOR_MANAGER_PROXY:$vm,
          VALIDATOR_PEERS:$peers,RPC_RELEASE:$rpcRelease,VALIDATOR_RELEASE:$validatorRelease,
          RELAYER_VERSION:$relayerVersion}}')"
    kubectl -n "$NAMESPACE" patch configmap l1-config --type merge -p "$patch" >/dev/null
}

create_or_update_secret() {
    local bundle="$1" result="$2" hash_file hash_value patch
    hash_file="$(jq -r '.consolePasswordHashFile // empty' <<<"$result")"
    if kubectl -n "$NAMESPACE" get secret "$RELAYER_SECRET" >/dev/null 2>&1; then
        local existing missing=""
        existing="$(kubectl -n "$NAMESPACE" get secret "$RELAYER_SECRET" -o json)"
        for key in keystore.json keystore-password console-session-secret; do
            jq -e --arg key "$key" '.data[$key] != null' >/dev/null <<<"$existing" || missing="${missing:+$missing, }$key"
        done
        [[ -z "$missing" ]] || die "existing Secret $NAMESPACE/$RELAYER_SECRET is missing preserved keys: $missing"
        hash_value=""
        [[ -n "$hash_file" ]] && hash_value="$(base64 <"$hash_file" | tr -d '\n')"
        patch="$(jq -cn --arg hash "$hash_value" '{data:{"console-password-hash":$hash}}')"
        kubectl -n "$NAMESPACE" patch secret "$RELAYER_SECRET" --type merge -p "$patch" >/dev/null
        return 0
    fi

    [[ -n "$hash_file" ]] || { hash_file="$bundle/console-password-hash"; : >"$hash_file"; }
    kubectl -n "$NAMESPACE" create secret generic "$RELAYER_SECRET" \
        --from-file="keystore.json=$bundle/keystore.json" \
        --from-file="keystore-password=$bundle/keystore-password" \
        --from-file="console-session-secret=$bundle/console-session-secret" \
        --from-file="console-password-hash=$hash_file" >/dev/null
    kubectl -n "$NAMESPACE" label secret "$RELAYER_SECRET" --overwrite \
        app.kubernetes.io/name=relayer-runtime \
        app.kubernetes.io/instance="$RELAYER_RELEASE" \
        app.kubernetes.io/part-of=avalanche-deploy >/dev/null

    PCHAIN_ADDRESS="$(jq -r '.pChainAddress' <<<"$result")"
    EVM_ADDRESS="$(jq -r '.evmAddress' <<<"$result")"
    local funding_patch
    funding_patch="$(jq -cn --arg p "$PCHAIN_ADDRESS" --arg e "$EVM_ADDRESS" \
        '{data:{RELAYER_PCHAIN_ADDRESS:$p,RELAYER_EVM_ADDRESS:$e}}')"
    kubectl -n "$NAMESPACE" patch configmap l1-config --type merge -p "$funding_patch" >/dev/null
}

install_relayer() {
    require_commands base64 curl find helm jq kubectl tar
    discover_namespace
    discover_l1_env
    discover_workloads
    discover_operator
    preflight
    discover_safe

    local target answer console_password bundle result setup_args peer peer_node peer_ip values_file
    target="$CONTEXT/$NAMESPACE/$RELAYER_POD"
    printf 'Install the relayer and console on %s? [y/N] ' "$target"
    IFS= read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Installation cancelled."; return 0 ;; esac
    printf 'Console password (press Enter for none): '
    IFS= read -r -s console_password
    printf '\n'

    download_setup
    bundle="$TMP_DIR/bundle"
    setup_args=(
        --out "$bundle"
        --subnet-id "$SUBNET_ID"
        --blockchain-id "$CHAIN_ID"
        --evm-chain-id "$EVM_CHAIN_ID"
        --chain-name "$CHAIN_NAME"
        --manager-address "$POA_MANAGER"
        --validator-manager-address "$VALIDATOR_MANAGER_PROXY"
        --network "$NETWORK"
        --pchain-rpc-url "http://127.0.0.1:$RPC_PORT"
        --info-rpc-url "http://127.0.0.1:$RPC_PORT"
        --evm-rpc-url "http://127.0.0.1:$RPC_PORT/ext/bc/$CHAIN_ID/rpc"
        --output json
    )
    [[ -n "$COIN_NAME" ]] && setup_args+=(--coin-name "$COIN_NAME")
    while IFS= read -r peer; do
        peer_node="$(jq -r '.nodeId' <<<"$peer")"
        peer_ip="$(jq -r '.ip' <<<"$peer")"
        setup_args+=(--peer "$peer_node@$peer_ip")
    done < <(jq -c '.[]' <<<"$VALIDATOR_PEERS_JSON")
    result="$(RELAYER_CONSOLE_PASSWORD="$console_password" "$SETUP_BIN" "${setup_args[@]}")"
    jq -e '.pChainAddress and .evmAddress' >/dev/null <<<"$result" || die "relayer-setup returned incomplete funding output"

    persist_l1_metadata
    create_or_update_secret "$bundle" "$result"

    values_file="$TMP_DIR/values.json"
    jq -n \
        --arg version "$RELAYER_VERSION" --arg network "$NETWORK" \
        --arg subnet "$SUBNET_ID" --arg chain "$CHAIN_ID" --argjson evm "$EVM_CHAIN_ID" \
        --arg chainName "$CHAIN_NAME" --arg coin "${COIN_NAME:-TOKEN}" \
        --arg manager "$POA_MANAGER" --arg vm "$VALIDATOR_MANAGER_PROXY" \
        --arg secret "$RELAYER_SECRET" --arg operator "$OPERATOR_IDENTITY" \
        --arg rpc "$RPC_SERVICE" --arg rpcRelease "$RPC_RELEASE" \
        --arg validatorRelease "$VALIDATOR_RELEASE" --argjson peers "$VALIDATOR_PEERS_JSON" \
        --argjson safe "$SAFE_ENABLED" --arg safeAddress "$POA_OWNER" \
        --arg safeRelease "$SAFE_RELEASE" --arg safeTxs "$SAFE_TXS_SERVICE" --arg safeUi "$SAFE_UI_SERVICE" \
        '{fullnameOverride:"relayer",images:{relayerd:{tag:$version},console:{tag:$version}},
          network:$network,l1:{subnetId:$subnet,blockchainId:$chain,evmChainId:$evm,
          chainName:$chainName,coinName:$coin,managerAddress:$manager,validatorManagerAddress:$vm},
          avalanchego:{serviceName:$rpc,httpPort:9650},runtimeSecret:{name:$secret},
          operatorIdentity:$operator,console:{origin:"http://127.0.0.1:3080",walletRpcTunnelPort:9652},manuallyTrackedPeers:$peers,
          networkPolicy:{rpc:{podSelector:{"app.kubernetes.io/name":"l1-rpc","app.kubernetes.io/instance":$rpcRelease}},
            validators:{podSelector:{"app.kubernetes.io/name":"l1-validator","app.kubernetes.io/instance":$validatorRelease},p2pPort:9651}},
          safe:{enabled:$safe,address:(if $safe then $safeAddress else "" end),
            transactionServiceUrl:(if $safe then "http://"+$safeTxs+":8888" else "" end),
            uiUrl:(if $safe and ($safeUi|length)>0 then "http://"+$safeUi+":8080" else "" end),port:8888,
            podSelector:(if $safe then {"app.kubernetes.io/name":"safe-txs","app.kubernetes.io/instance":$safeRelease} else {"app.kubernetes.io/name":"safe-txs"} end)}}' \
        >"$values_file"

    if ! helm upgrade --install "$RELAYER_RELEASE" "$K8S_DIR/helm/relayerd" -n "$NAMESPACE" \
        -f "$values_file" --atomic --wait --timeout "$TIMEOUT"; then
        die "Relayer Helm installation failed; the preserved runtime Secret was not deleted"
    fi
    kubectl -n "$NAMESPACE" rollout status statefulset/relayer --timeout="$TIMEOUT"

    PCHAIN_ADDRESS="$(config_value RELAYER_PCHAIN_ADDRESS)"
    EVM_ADDRESS="$(config_value RELAYER_EVM_ADDRESS)"
    if [[ -z "$PCHAIN_ADDRESS" || -z "$EVM_ADDRESS" ]]; then
        local keys_json
        keys_json="$(kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c console -- \
            node -e 'fetch("http://127.0.0.1:8080/keys").then(r=>r.json()).then(v=>process.stdout.write(JSON.stringify(v)))' 2>/dev/null || true)"
        PCHAIN_ADDRESS="$(jq -r '.pchainFloatAddress // empty' <<<"$keys_json")"
        EVM_ADDRESS="$(jq -r '.gasKeyAddress // empty' <<<"$keys_json")"
        if [[ -n "$PCHAIN_ADDRESS" && -n "$EVM_ADDRESS" ]]; then
            kubectl -n "$NAMESPACE" patch configmap l1-config --type merge \
                -p "$(jq -cn --arg p "$PCHAIN_ADDRESS" --arg e "$EVM_ADDRESS" \
                    '{data:{RELAYER_PCHAIN_ADDRESS:$p,RELAYER_EVM_ADDRESS:$e}}')" >/dev/null
        fi
    fi
    [[ -n "$PCHAIN_ADDRESS" && -n "$EVM_ADDRESS" ]] || \
        die "relayer is ready, but funding addresses could not be read; inspect make k8s-relayer-logs"
    echo "Relayer and console are ready in $NAMESPACE/$RELAYER_POD."
    echo "Funding addresses:"
    echo "  P-chain float: $PCHAIN_ADDRESS"
    echo "  L1 EVM gas:    $EVM_ADDRESS"
    echo "Access: make k8s-relayer-access"
}

discover_installed() {
    require_commands helm jq kubectl
    discover_namespace
    discover_workloads
    helm status "$RELAYER_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 || \
        die "Relayer release '$RELAYER_RELEASE' is not installed in namespace '$NAMESPACE'"
}

access_relayer() {
    discover_installed
    echo "Console: http://127.0.0.1:$LOCAL_CONSOLE_PORT"
    echo "L1 RPC:  http://127.0.0.1:$LOCAL_RPC_PORT/ext/bc/$(config_value CHAIN_ID)/rpc"
    kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 \
        "service/$RPC_SERVICE" "${LOCAL_RPC_PORT}:9650" >/dev/null 2>&1 &
    PF_PID=$!
    kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 \
        "pod/$RELAYER_POD" "${LOCAL_CONSOLE_PORT}:3080"
}

status_relayer() {
    discover_installed
    kubectl -n "$NAMESPACE" get statefulset/relayer "pod/$RELAYER_POD" -o wide
    kubectl -n "$NAMESPACE" get pvc -l app.kubernetes.io/instance="$RELAYER_RELEASE"
}

logs_relayer() {
    discover_installed
    kubectl -n "$NAMESPACE" logs -f "$RELAYER_POD" --all-containers=true --prefix=true
}

backup_relayer() {
    discover_installed
    local backup_pod="relayer-manual-backup" timestamp replicas pod_manifest
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    replicas="$(kubectl -n "$NAMESPACE" get statefulset relayer -o jsonpath='{.spec.replicas}')"
    BACKUP_REPLICAS="$replicas"
    echo "Draining relayer before backup..."
    kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas=0 >/dev/null
    kubectl -n "$NAMESPACE" wait --for=delete "pod/$RELAYER_POD" --timeout="$TIMEOUT" >/dev/null || true
    kubectl -n "$NAMESPACE" delete pod "$backup_pod" --ignore-not-found --wait >/dev/null
    pod_manifest="$(jq -cn --arg name "$backup_pod" --arg claim "data-relayer-0" --arg timestamp "$timestamp" '
      {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-backup"}},
       spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
       containers:[{name:"backup",image:"busybox:1.37.0",command:["sh","-ec"],
       args:["cd /data; archive=backups/manual-"+$timestamp+".tar.gz; mkdir -p backups; entries=$(find . -mindepth 1 -maxdepth 1 ! -name backups -print); test -n \"$entries\"; tar -czf \"$archive\" $entries; echo ${archive##*/}"],
       volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],
       volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
    if ! printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null || \
       ! kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$backup_pod" --timeout="$TIMEOUT" >/dev/null; then
        kubectl -n "$NAMESPACE" logs "$backup_pod" 2>/dev/null || true
        die "manual backup failed; the relayer was restarted"
    fi
    kubectl -n "$NAMESPACE" logs "$backup_pod"
    kubectl -n "$NAMESPACE" delete pod "$backup_pod" --wait >/dev/null
    kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas="$replicas" >/dev/null
    kubectl -n "$NAMESPACE" rollout status statefulset/relayer --timeout="$TIMEOUT"
    BACKUP_REPLICAS=""
}

upgrade_relayer() {
    discover_installed
    [[ "$RELAYER_VERSION" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || die "invalid RELAYER_VERSION: $RELAYER_VERSION"
    local revision
    revision="$(helm history "$RELAYER_RELEASE" -n "$NAMESPACE" -o json | jq -r 'map(select(.status == "deployed")) | last | .revision')"
    backup_relayer
    echo "Upgrading Relayer to $RELAYER_VERSION..."
    if ! helm upgrade "$RELAYER_RELEASE" "$K8S_DIR/helm/relayerd" -n "$NAMESPACE" \
        --reuse-values --set "images.relayerd.tag=$RELAYER_VERSION" \
        --set "images.console.tag=$RELAYER_VERSION" --wait --timeout "$TIMEOUT"; then
        echo "Upgrade failed; rolling back to Helm revision $revision..." >&2
        helm rollback "$RELAYER_RELEASE" "$revision" -n "$NAMESPACE" --wait --timeout "$TIMEOUT"
        die "upgrade failed and the prior revision was restored"
    fi
    kubectl -n "$NAMESPACE" patch configmap l1-config --type merge \
        -p "$(jq -cn --arg version "$RELAYER_VERSION" '{data:{RELAYER_VERSION:$version}}')" >/dev/null
    kubectl -n "$NAMESPACE" rollout status statefulset/relayer --timeout="$TIMEOUT"
}

remove_relayer() {
    require_commands helm jq kubectl
    discover_namespace
    if helm status "$RELAYER_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
        helm uninstall "$RELAYER_RELEASE" -n "$NAMESPACE" --wait --timeout "$TIMEOUT"
    else
        echo "Relayer release is already absent from namespace '$NAMESPACE'."
    fi
    if [[ "${PURGE:-false}" != "true" ]]; then
        echo "Relayer workload removed. Secret, PVC, TLS identity, state, and backups were preserved."
        return 0
    fi

    local confirmation
    printf 'Permanently delete relayer keys, state, TLS identity, and backups in %s? Type PURGE to continue: ' "$NAMESPACE"
    IFS= read -r confirmation
    [[ "$confirmation" == "PURGE" ]] || { echo "Purge cancelled; retained data was preserved."; return 0; }
    kubectl -n "$NAMESPACE" delete secret "$RELAYER_SECRET" --ignore-not-found
    kubectl -n "$NAMESPACE" delete pvc -l app.kubernetes.io/instance="$RELAYER_RELEASE"
    kubectl -n "$NAMESPACE" patch configmap l1-config --type=merge \
        -p='{"data":{"RELAYER_PCHAIN_ADDRESS":null,"RELAYER_EVM_ADDRESS":null,"RELAYER_VERSION":null}}' >/dev/null
    echo "Relayer keys, state, TLS identity, and backups permanently deleted."
}

case "$ACTION" in
    install) install_relayer ;;
    access) access_relayer ;;
    status) status_relayer ;;
    logs) logs_relayer ;;
    backup) backup_relayer ;;
    upgrade) upgrade_relayer ;;
    remove) remove_relayer ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
esac
