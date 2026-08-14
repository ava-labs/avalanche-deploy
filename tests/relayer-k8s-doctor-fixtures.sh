#!/usr/bin/env bash
# Stable diagnostic result and exit-code fixtures for the Kubernetes Relayer doctor.
#
# kubernetes/scripts/relayer.sh guards main "$@" behind a BASH_SOURCE equality test,
# so this suite sources it and calls the real doctor and discovery functions. Only
# the leaf commands that would touch a cluster or the network are replaced:
# kubectl, helm, curl, and release_curl. Namespace discovery, RBAC probing,
# workload/runtime classification, discover_workloads, preflight (including
# PoAManager owner classification through the real rpc_call/evm_call/contract_call
# chain), discover_validator_peers, and discover_safe all execute for real.
#
# Two properties are only real at real scale, so they have dedicated coverage:
# the Info API peer set and the Primary Network validator set are hundreds of
# kilobytes on Fuji and larger on Mainnet, and doctor_k8s takes the same
# install|operations scope argument doctor_vm does.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_SCRIPT="$ROOT_DIR/kubernetes/scripts/relayer.sh"
# shellcheck source=kubernetes/scripts/relayer.sh
source "$K8S_SCRIPT"

# The sourced script installs its own cleanup trap and owns the name TMP_DIR, so
# this suite keeps its workspace in FIXTURE_DIR and claims the trap afterwards.
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relayer-k8s-doctor-fixtures.XXXXXX")"

# The port-forward scenarios replace kubectl port-forward with a real long-lived
# process, so a suite that dies mid-case must not leave one behind.
PF_WITNESS_FILE="$FIXTURE_DIR/port-forward-witness"
reap_port_forward_witnesses() {
    local pid
    [[ -s "$PF_WITNESS_FILE" ]] || return 0
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill "$pid" >/dev/null 2>&1 || true
    done <"$PF_WITNESS_FILE"
}
trap 'reap_port_forward_witnesses; rm -rf "$FIXTURE_DIR"' EXIT INT TERM

fail() {
    echo "Kubernetes Relayer doctor fixture failed: $*" >&2
    exit 1
}

# --------------------------------------------------------------- fixture identity
FIXTURE_CONTEXT="test-context"
FIXTURE_NAMESPACE="team-l1"
FIXTURE_IDENTITY="operator@example.test"
FIXTURE_RPC_SERVICE="rpc-service"
FIXTURE_RPC_RELEASE="rpc-release"
FIXTURE_VALIDATOR_RELEASE="validator-release"
FIXTURE_VALIDATOR_POD="validator-0"
FIXTURE_VALIDATOR_NODE_ID="NodeID-FixtureValidator1"
FIXTURE_SUBNET_ID="2FixtureSubnetIdentifier"
FIXTURE_CHAIN_ID="2FixtureBlockchainIdentifier"
FIXTURE_CHAIN_NAME="fixture-chain"
FIXTURE_EVM_CHAIN_ID="99999"
FIXTURE_POA_MANAGER="0x1111111111111111111111111111111111111111"
FIXTURE_VALIDATOR_MANAGER="0x2222222222222222222222222222222222222222"
FIXTURE_POA_OWNER="0x3333333333333333333333333333333333333333"
FIXTURE_VERSION="v0.1.0"
FIXTURE_RELAYERD_IMAGE="ghcr.io/ava-labs/relayerd@sha256:$(printf 'a%.0s' {1..64})"
FIXTURE_CONSOLE_IMAGE="ghcr.io/ava-labs/relayer-console@sha256:$(printf 'b%.0s' {1..64})"
FIXTURE_BACKUP_ARCHIVE="manual-20260801T120000Z.tar.gz"
FIXTURE_GOOD_SHA="$(printf 'c%.0s' {1..64})"
FIXTURE_BAD_SHA="$(printf 'd%.0s' {1..64})"
FIXTURE_RECENT_BACKUP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FIXTURE_STALE_BACKUP="2020-01-01T00:00:00Z"

address_word() { printf '0x%024d%s\n' 0 "${1#0x}"; }
uint_word() { printf '0x%064x\n' "$1"; }

# ------------------------------------------------------------ fixture workspaces
# The doctor reads the generated l1.env from ROOT_DIR/K8S_DIR, so every run points
# both at one of these fixture workspaces and never at the real checkout.
mkdir -p "$FIXTURE_DIR/ws" "$FIXTURE_DIR/ws-mismatch" "$FIXTURE_DIR/ws-empty"
write_l1_env() {
    local path="$1" chain_name="$2"
    cat >"$path/l1.env" <<ENV
NETWORK=fuji
SUBNET_ID=$FIXTURE_SUBNET_ID
CHAIN_ID=$FIXTURE_CHAIN_ID
EVM_CHAIN_ID=$FIXTURE_EVM_CHAIN_ID
CHAIN_NAME=$chain_name
POA_MANAGER=$FIXTURE_POA_MANAGER
VALIDATOR_MANAGER_PROXY=$FIXTURE_VALIDATOR_MANAGER
ENV
}
write_l1_env "$FIXTURE_DIR/ws" "$FIXTURE_CHAIN_NAME"
write_l1_env "$FIXTURE_DIR/ws-mismatch" "renamed-chain"

# ------------------------------------------------------------------ scenario knobs
# Every stub reads these at call time, so a run only exports what it changes.
: "${SC_CONTEXT:=$FIXTURE_CONTEXT}"
: "${SC_NS:=current}"           # current|fallback|denied|multiple|zero
: "${SC_ALLNS:=one}"            # one|zero|multiple|fail
: "${SC_IDENTITY:=$FIXTURE_IDENTITY}"
: "${SC_RBAC_DENY:=}"           # "<verb> <resource>" denied by auth can-i
: "${SC_WORKLOADS:=ok}"         # ok|missing
: "${SC_STS:=true}"
: "${SC_SECRET:=true}"
: "${SC_PVC:=1}"
: "${SC_READY:=1}"
: "${SC_IMAGES:=digest}"        # digest|tag
: "${SC_RELEASE:=ok}"           # ok|missing
: "${SC_INFO_URL:=http://$FIXTURE_RPC_SERVICE:9650}"
: "${SC_OWNER:=safe}"           # safe|eoa|zero|unanswered|rpc-error|not-safe
: "${SC_PEERS:=visible}"        # visible|missing
: "${SC_ELIGIBLE:=2}"
: "${SC_SAFE:=present}"         # present|absent|multiple|no-txs
: "${SC_CONSOLE_ENV:=full}"     # full|partial|none
: "${SC_TXS_OK:=true}"
: "${SC_KEYSTORE_OK:=true}"
: "${SC_HOT_BACKUP:=valid}"     # valid|corrupt|absent
: "${SC_FUNDING:=ok}"           # ok|low
: "${SC_LAST_BACKUP:=$FIXTURE_RECENT_BACKUP}"
: "${SC_ARCHIVE:=valid}"        # valid|mismatch|nomanifest|none
: "${SC_WS:=$FIXTURE_DIR/ws}"
: "${SC_SCOPE:=operations}"     # operations|install
: "${SC_PAYLOAD:=small}"        # small|match|disjoint  (see section 13)
: "${SC_PRIVACY:=none}"         # none|content|content-public|dir|file
: "${SC_PF_WITNESS:=}"          # when set, port-forward spawns a real recorded process

# ------------------------------------------------- realistically sized payloads
# A few hundred bytes of peers and validators cannot tell a working check from one
# that passes its response through argv, so the payload scenarios use the sizes a
# real Info API and P-Chain return: a measured Fuji platform.getCurrentValidators
# is ~800KB and Mainnet is larger, while Linux caps a single argv element at
# 131072 bytes and this host caps the whole vector at 1048576. The files are
# generated once here and reused, because rebuilding them per case is the only
# part of this that is not free.
FIXTURE_LARGE_PEER_COUNT=2000
FIXTURE_LARGE_VALIDATOR_COUNT=1000
FIXTURE_LARGE_ELIGIBLE="$FIXTURE_LARGE_VALIDATOR_COUNT"
FIXTURE_LARGE_PEERS="$FIXTURE_DIR/large-info-peers.json"
FIXTURE_LARGE_VALIDATORS="$FIXTURE_DIR/large-primary-validators.json"
FIXTURE_LARGE_OTHER_VALIDATORS="$FIXTURE_DIR/large-primary-validators-disjoint.json"
FIXTURE_LARGE_SUBNET_VALIDATORS="$FIXTURE_DIR/large-subnet-validators.json"
FIXTURE_LARGE_BLOCKCHAINS="$FIXTURE_DIR/large-blockchains.json"

large_validator_set() {
    # Shaped like a real platform.getCurrentValidators entry, including the BLS
    # signer and reward owners that make the response as large as it is.
    jq -cn --argjson count "$FIXTURE_LARGE_VALIDATOR_COUNT" --arg prefix "$1" '
      {result:{validators:[range($count) | {
         txID:("2FixtureStakingTransaction" + (.|tostring) + "AAAAAAAAAAAAAAAAAAAAAAA"),
         nodeID:($prefix + (.|tostring)),
         startTime:"1750000000", endTime:"1781536000",
         stakeAmount:"2000000000000", weight:"2000000000000",
         potentialReward:"123456789012", delegationFee:"2.0000",
         uptime:"0.9987", connected:true,
         signer:{
           publicKey:"0xb1c2d3e4f5061728394a5b6c7d8e9f00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00",
           proofOfPossession:"0xa0b1c2d3e4f5061728394a5b6c7d8e9f00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"},
         validationRewardOwner:{locktime:"0",threshold:"1",addresses:["P-fuji1fixturerewardowneraddress000000000000"]},
         delegationRewardOwner:{locktime:"0",threshold:"1",addresses:["P-fuji1fixturerewardowneraddress000000000000"]},
         delegatorCount:"0", delegatorWeight:"0"}]}}'
}

large_validator_set NodeID-FixturePrimary >"$FIXTURE_LARGE_VALIDATORS"
large_validator_set NodeID-FixtureUnrelated >"$FIXTURE_LARGE_OTHER_VALIDATORS"
jq -cn --argjson count "$FIXTURE_LARGE_PEER_COUNT" --arg node "$FIXTURE_VALIDATOR_NODE_ID" \
    --arg subnet "$FIXTURE_SUBNET_ID" '
  {result:{peers:([{nodeID:$node,ip:"10.42.0.7:9651",publicIP:"10.42.0.7:9651",
      version:"avalanchego/1.13.4",lastSent:"2026-08-14T00:00:00Z",
      lastReceived:"2026-08-14T00:00:00Z",observedUptime:"99",
      trackedSubnets:[$subnet],benched:[]}]
    + [range($count) | {nodeID:("NodeID-FixturePrimary" + (.|tostring)),
        ip:("10.60." + ((./256|floor)|tostring) + "." + ((.%256)|tostring) + ":9651"),
        publicIP:("52.32." + ((./256|floor)|tostring) + "." + ((.%256)|tostring) + ":9651"),
        version:"avalanchego/1.13.4",lastSent:"2026-08-14T00:00:00Z",
        lastReceived:"2026-08-14T00:00:00Z",observedUptime:"98",
        trackedSubnets:["11111111111111111111111111111111LpoYY"],benched:[]}])}}' \
    >"$FIXTURE_LARGE_PEERS"
# preflight's subnet-scoped validator read and its blockchain lookup consume the
# other two responses whose size an operator does not control.
jq -cn --arg node "$FIXTURE_VALIDATOR_NODE_ID" '
  {result:{validators:([{nodeID:$node,weight:"1",startTime:"1750000000",endTime:"1781536000",connected:true}]
    + [range(120) | {nodeID:("NodeID-FixtureSubnetPeer" + (.|tostring)),weight:"1",
        startTime:"1750000000",endTime:"1781536000",connected:true}])}}' \
    >"$FIXTURE_LARGE_SUBNET_VALIDATORS"
jq -cn --arg chain "$FIXTURE_CHAIN_ID" --arg subnet "$FIXTURE_SUBNET_ID" \
    --arg name "$FIXTURE_CHAIN_NAME" '
  {result:{blockchains:([{id:$chain,subnetID:$subnet,name:$name,vmID:"srEXiWaHuhNyGwPUi444Tu47ZEDwxTWrbQiuD7FmgSAQ6X7Dy"}]
    + [range(400) | {id:("2FixtureOtherBlockchain" + (.|tostring)),
        subnetID:("2FixtureOtherSubnet" + (.|tostring)),
        name:("other-chain-" + (.|tostring)),
        vmID:"srEXiWaHuhNyGwPUi444Tu47ZEDwxTWrbQiuD7FmgSAQ6X7Dy"}])}}' \
    >"$FIXTURE_LARGE_BLOCKCHAINS"
# A payload that fits in one argv element would make section 14 vacuous again.
for payload in "$FIXTURE_LARGE_PEERS" "$FIXTURE_LARGE_VALIDATORS" "$FIXTURE_LARGE_OTHER_VALIDATORS"; do
    payload_bytes="$(wc -c <"$payload" | tr -d '[:space:]')"
    [[ "$payload_bytes" -gt 131072 ]] || \
        fail "$payload is only $payload_bytes bytes, which no longer exercises a realistic RPC response"
done

# ------------------------------------------------------------------ fixture JSON
l1_config_json() {
    jq -cn \
        --arg subnet "$FIXTURE_SUBNET_ID" --arg chain "$FIXTURE_CHAIN_ID" \
        --arg evm "$FIXTURE_EVM_CHAIN_ID" --arg chainName "$FIXTURE_CHAIN_NAME" \
        --arg poa "$FIXTURE_POA_MANAGER" --arg vm "$FIXTURE_VALIDATOR_MANAGER" \
        --arg rpcRelease "$FIXTURE_RPC_RELEASE" --arg validatorRelease "$FIXTURE_VALIDATOR_RELEASE" \
        --arg version "$FIXTURE_VERSION" --arg rpcService "$FIXTURE_RPC_SERVICE" \
        --arg daemon "$FIXTURE_RELAYERD_IMAGE" --arg console "$FIXTURE_CONSOLE_IMAGE" \
        --arg lastBackup "$SC_LAST_BACKUP" \
        '{data:{NETWORK:"fuji",SUBNET_ID:$subnet,CHAIN_ID:$chain,EVM_CHAIN_ID:$evm,
          CHAIN_NAME:$chainName,POA_MANAGER:$poa,VALIDATOR_MANAGER_PROXY:$vm,
          RPC_RELEASE:$rpcRelease,VALIDATOR_RELEASE:$validatorRelease,
          RELAYER_VERSION:$version,RELAYER_RPC_SERVICE:$rpcService,
          RELAYERD_IMAGE:$daemon,RELAYER_CONSOLE_IMAGE:$console,
          RELAYER_LAST_BACKUP:$lastBackup}}
         | if $lastBackup == "" then del(.data.RELAYER_LAST_BACKUP) else . end'
}

statefulset_json() {
    local console_env='[]' console_image="$FIXTURE_CONSOLE_IMAGE"
    case "$SC_CONSOLE_ENV" in
        full) console_env="$(jq -cn '[{name:"SAFE_ADDRESS",value:"0x3333333333333333333333333333333333333333"},
              {name:"SAFE_TX_SERVICE_URL",value:"http://safe-txs:8888"},
              {name:"SAFE_UI_URL",value:"http://safe-ui:8081"}]')" ;;
        partial) console_env="$(jq -cn '[{name:"SAFE_ADDRESS",value:"0x3333333333333333333333333333333333333333"},
              {name:"SAFE_TX_SERVICE_URL",value:"http://safe-txs:8888"},
              {name:"SAFE_UI_URL",value:""}]')" ;;
        none) console_env='[]' ;;
    esac
    [[ "$SC_IMAGES" == digest ]] || console_image="ghcr.io/ava-labs/relayer-console:$FIXTURE_VERSION"
    jq -cn --argjson env "$console_env" --argjson ready "$SC_READY" \
        --arg utility "$UTILITY_IMAGE" --arg daemon "$FIXTURE_RELAYERD_IMAGE" --arg console "$console_image" '
        {spec:{replicas:1,template:{spec:{
           initContainers:[{name:"initialize-keystore",image:$utility}],
           containers:[{name:"relayerd",image:$daemon,env:[]},{name:"console",image:$console,env:$env}],
           volumes:[{name:"data"},{name:"config",configMap:{name:"relayer-config"}}]}}},
         status:{readyReplicas:$ready}}'
}

peers_json() {
    if [[ "$SC_PAYLOAD" != small ]]; then
        cat "$FIXTURE_LARGE_PEERS"
        return 0
    fi
    local peers='[]'
    [[ "$SC_PEERS" == missing ]] || \
        peers="$(jq -cn --arg node "$FIXTURE_VALIDATOR_NODE_ID" '[{nodeID:$node}]')"
    jq -cn --argjson peers "$peers" --argjson eligible "$SC_ELIGIBLE" \
        '{result:{peers:($peers + [range($eligible) | {nodeID:("NodeID-FixturePrimary" + (.|tostring))}])}}'
}

# The pod spec discover_validator_peers reads to tell a protocol-private validator
# from an ordinary peering failure. AvalancheGo takes validatorOnly either from
# --subnet-config-content on the container or from <subnet-config-dir>/<id>.json,
# so both routes are represented.
validator_pod_json() {
    local args='[]' env='[]' subnet_config
    case "$SC_PRIVACY" in
        content|content-public)
            subnet_config="$(jq -cn --arg subnet "$FIXTURE_SUBNET_ID" \
                --argjson private "$([[ "$SC_PRIVACY" == content ]] && echo true || echo false)" \
                '{($subnet):{validatorOnly:$private}}' | base64 | tr -d '\n')"
            args="$(jq -cn --arg content "$subnet_config" '["--subnet-config-content=" + $content]')"
            ;;
        dir) args='["--subnet-config-dir=/etc/avalanchego/subnets"]' ;;
        file) env='[{"name":"HOME","value":"/data"}]' ;;
    esac
    jq -cn --arg pod "$FIXTURE_VALIDATOR_POD" --argjson args "$args" --argjson env "$env" \
        '{metadata:{name:$pod},
          spec:{containers:[{name:"avalanchego",command:["/avalanchego/build/avalanchego"],
            args:$args,env:$env}]},
          status:{podIP:"10.42.0.7"}}'
}

archive_exec_output() {
    case "$SC_ARCHIVE" in
        valid)
            printf 'ARCHIVE %s %s\n' "$FIXTURE_BACKUP_ARCHIVE" "$FIXTURE_GOOD_SHA"
            backup_manifest_json "$FIXTURE_GOOD_SHA" ;;
        mismatch)
            printf 'ARCHIVE %s %s\n' "$FIXTURE_BACKUP_ARCHIVE" "$FIXTURE_BAD_SHA"
            backup_manifest_json "$FIXTURE_GOOD_SHA" ;;
        nomanifest) printf 'NOMANIFEST %s\n' "$FIXTURE_BACKUP_ARCHIVE" ;;
        none) printf 'NONE\n' ;;
    esac
}

backup_manifest_json() {
    jq -cn --arg archive "$FIXTURE_BACKUP_ARCHIVE" --arg sha "$1" \
        '{schemaVersion:1,kind:"avalanche-deploy-relayer-backup",archive:{file:$archive,sha256:$sha}}'
}

# ------------------------------------------------------------------- tool stubs
helm() {
    case "$*" in
        *'list -n '*'-o json')
            case "$SC_SAFE" in
                absent) printf '[]' ;;
                multiple) printf '[{"name":"safe-one","chart":"safe-1.0.0"},{"name":"safe-two","chart":"safe-1.0.0"}]' ;;
                *) printf '[{"name":"safe","chart":"safe-1.0.0"}]' ;;
            esac
            return 0
            ;;
    esac
    return 0
}

release_curl() {
    local url="${*: -1}"
    case "$url" in
        *checksums.txt) [[ "$SC_RELEASE" == ok ]] ;;
        *relayerd-image.txt) printf '%s\n' "$FIXTURE_RELAYERD_IMAGE" ;;
        *relayer-console-image.txt) printf '%s\n' "$FIXTURE_CONSOLE_IMAGE" ;;
        *) return 1 ;;
    esac
}

# The real rpc_call/evm_call/contract_call, and therefore the real JSON-RPC error
# handling, run on top of this: it answers the HTTP POST the script actually makes.
curl() {
    local argument previous="" url="" body=""
    for argument in "$@"; do
        [[ "$previous" != -d ]] || body="$argument"
        case "$argument" in http://*) url="$argument" ;; esac
        previous="$argument"
    done
    [[ -n "$url" ]] || return 1
    local method params address selector
    method="$(jq -r '.method // empty' <<<"$body" 2>/dev/null || true)"
    params="$(jq -c '.params // {}' <<<"$body" 2>/dev/null || true)"
    case "$method" in
        info.getNodeID) jq -cn --arg node "$FIXTURE_VALIDATOR_NODE_ID" '{result:{nodeID:$node}}' ;;
        info.getNetworkID) jq -cn '{result:{networkID:"5"}}' ;;
        info.isBootstrapped) jq -cn '{result:{isBootstrapped:true}}' ;;
        info.peers) peers_json ;;
        platform.getCurrentValidators)
            if [[ "$params" == *subnetID* ]]; then
                if [[ "$SC_PAYLOAD" != small ]]; then
                    cat "$FIXTURE_LARGE_SUBNET_VALIDATORS"
                else
                    jq -cn --arg node "$FIXTURE_VALIDATOR_NODE_ID" '{result:{validators:[{nodeID:$node}]}}'
                fi
            else
                case "$SC_PAYLOAD" in
                    match) cat "$FIXTURE_LARGE_VALIDATORS" ;;
                    disjoint) cat "$FIXTURE_LARGE_OTHER_VALIDATORS" ;;
                    *) jq -cn '{result:{validators:[range(3) | {nodeID:("NodeID-FixturePrimary" + (.|tostring))}]}}' ;;
                esac
            fi
            ;;
        platform.getBlockchains)
            if [[ "$SC_PAYLOAD" != small ]]; then
                cat "$FIXTURE_LARGE_BLOCKCHAINS"
            else
                jq -cn --arg chain "$FIXTURE_CHAIN_ID" --arg subnet "$FIXTURE_SUBNET_ID" \
                    --arg name "$FIXTURE_CHAIN_NAME" \
                    '{result:{blockchains:[{id:$chain,subnetID:$subnet,name:$name}]}}'
            fi
            ;;
        eth_chainId) jq -cn '{result:"0x1869f"}' ;;
        eth_getCode)
            address="$(jq -r '.[0] // empty' <<<"$params")"
            case "$(tr '[:upper:]' '[:lower:]' <<<"$address")" in
                "$FIXTURE_POA_MANAGER") jq -cn '{result:"0x608060405289f9f85b00"}' ;;
                "$FIXTURE_VALIDATOR_MANAGER") jq -cn '{result:"0x6080604052"}' ;;
                *)
                    case "$SC_OWNER" in
                        safe|not-safe) jq -cn '{result:"0x60806040"}' ;;
                        eoa) jq -cn '{result:"0x"}' ;;
                        unanswered) jq -cn '{jsonrpc:"2.0",id:1}' ;;
                        rpc-error) jq -cn '{jsonrpc:"2.0",id:1,error:{code:-32000,message:"execution reverted"}}' ;;
                        *) jq -cn '{result:"0x"}' ;;
                    esac
                    ;;
            esac
            ;;
        eth_call)
            address="$(tr '[:upper:]' '[:lower:]' <<<"$(jq -r '.[0].to // empty' <<<"$params")")"
            selector="$(jq -r '.[0].data // empty' <<<"$params")"
            case "$address:$selector" in
                "$FIXTURE_VALIDATOR_MANAGER:0x8da5cb5b")
                    jq -cn --arg word "$(address_word "$FIXTURE_POA_MANAGER")" '{result:$word}' ;;
                "$FIXTURE_VALIDATOR_MANAGER:0x5bd93e88")
                    jq -cn --arg word "$(uint_word 1)" '{result:$word}' ;;
                "$FIXTURE_POA_MANAGER:0x8da5cb5b")
                    if [[ "$SC_OWNER" == zero ]]; then
                        jq -cn --arg word "$(uint_word 0)" '{result:$word}'
                    else
                        jq -cn --arg word "$(address_word "$FIXTURE_POA_OWNER")" '{result:$word}'
                    fi
                    ;;
                "$FIXTURE_POA_OWNER:0xe75235b8")
                    if [[ "$SC_OWNER" == not-safe ]]; then
                        jq -cn --arg word "$(uint_word 0)" '{result:$word}'
                    else
                        jq -cn --arg word "$(uint_word 2)" '{result:$word}'
                    fi
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

kubectl() {
    local all="$*" verb resource
    case "$all" in
        'config current-context') [[ -n "$SC_CONTEXT" ]] && printf '%s' "$SC_CONTEXT" ;;
        'auth whoami -o json')
            [[ -n "$SC_IDENTITY" ]] || return 1
            jq -cn --arg user "$SC_IDENTITY" '{status:{userInfo:{username:$user}}}'
            ;;
        *'config view --minify'*)
            [[ "$SC_NS" == current ]] && printf '%s' "$FIXTURE_NAMESPACE" || printf 'default'
            ;;
        *'auth can-i list configmaps --all-namespaces'*)
            [[ "$SC_NS" == denied ]] && printf 'no' || printf 'yes'
            ;;
        'get configmaps --all-namespaces -o json')
            case "$SC_ALLNS" in
                fail) return 1 ;;
                zero) printf '{"items":[]}' ;;
                multiple) printf '{"items":[{"metadata":{"name":"l1-config","namespace":"one"}},{"metadata":{"name":"l1-config","namespace":"two"}}]}' ;;
                *) printf '{"items":[{"metadata":{"name":"l1-config","namespace":"fallback-l1"}}]}' ;;
            esac
            ;;
        *'auth can-i list storageclasses.storage.k8s.io'*) printf 'no' ;;
        *'auth can-i '*)
            read -r _ _ verb resource _ <<<"$all"
            [[ "$verb $resource" != "$SC_RBAC_DENY" ]] && printf 'yes' || printf 'no'
            ;;
        *'get configmap l1-config -o json') l1_config_json ;;
        *'get configmap l1-config') [[ "$SC_NS" == current ]] ;;
        *'get configmap relayer-config -o json')
            jq -cn --arg url "$SC_INFO_URL" '{data:{"config.json":({"info-rpc-url":$url}|tojson)}}' ;;
        *'get services -l app.kubernetes.io/name=l1-rpc -o json')
            [[ "$SC_WORKLOADS" == ok ]] || { printf '{"items":[]}'; return 0; }
            jq -cn --arg name "$FIXTURE_RPC_SERVICE" --arg instance "$FIXTURE_RPC_RELEASE" \
                '{items:[{metadata:{name:$name,labels:{"app.kubernetes.io/instance":$instance}}}]}'
            ;;
        *'get statefulsets -l app.kubernetes.io/name=l1-validator -o json')
            [[ "$SC_WORKLOADS" == ok ]] || { printf '{"items":[]}'; return 0; }
            jq -cn --arg instance "$FIXTURE_VALIDATOR_RELEASE" \
                '{items:[{metadata:{labels:{"app.kubernetes.io/instance":$instance}}}]}'
            ;;
        *"get pvc -l app.kubernetes.io/name=l1-rpc,app.kubernetes.io/instance=$FIXTURE_RPC_RELEASE -o json")
            printf '{"items":[{"spec":{"accessModes":["ReadWriteOnce"],"storageClassName":"managed-rwo"},"status":{"phase":"Bound"}}]}'
            ;;
        *'get secret relayer-runtime') [[ "$SC_SECRET" == true ]] ;;
        *'get pvc -l app.kubernetes.io/instance=relayer -o json')
            if [[ "$SC_PVC" -eq 1 ]]; then
                printf '{"items":[{"spec":{"accessModes":["ReadWriteOnce"]}}]}'
            else
                printf '{"items":[]}'
            fi
            ;;
        *'get statefulset relayer -o json') statefulset_json ;;
        *'get statefulset relayer') [[ "$SC_STS" == true ]] ;;
        *'get networkpolicy relayer') return 0 ;;
        *'get rolebinding relayer-port-forward -o json')
            jq -cn --arg user "$SC_IDENTITY" \
                '{subjects:[{kind:"User",name:$user}],roleRef:{kind:"Role",name:"relayer-port-forward"}}'
            ;;
        *'get role relayer-port-forward -o json')
            jq -cn --arg rpc "$FIXTURE_RPC_SERVICE" '{rules:[
                {apiGroups:[""],resources:["pods"],verbs:["get","list"]},
                {apiGroups:[""],resources:["pods/portforward"],verbs:["create"]},
                {apiGroups:[""],resources:["services"],verbs:["get"],resourceNames:[$rpc]},
                {apiGroups:[""],resources:["configmaps"],verbs:["get"],resourceNames:["l1-config"]}]}'
            ;;
        *'get services -l app.kubernetes.io/instance=relayer -o json') printf '{"items":[]}' ;;
        *'get ingress -l app.kubernetes.io/instance=relayer -o json') printf '{"items":[]}' ;;
        *'get services -l app.kubernetes.io/name=safe-txs,'*)
            [[ "$SC_SAFE" == no-txs ]] && { printf '{"items":[]}'; return 0; }
            printf '{"items":[{"metadata":{"name":"safe-txs"}}]}'
            ;;
        *'get services -l app.kubernetes.io/name=safe-ui,'*)
            printf '{"items":[{"metadata":{"name":"safe-ui"}}]}'
            ;;
        *'get pods -l app.kubernetes.io/name=l1-validator,'*)
            jq -cn --arg pod "$FIXTURE_VALIDATOR_POD" '{items:[{metadata:{name:$pod}}]}'
            ;;
        *"get pod $FIXTURE_VALIDATOR_POD -o jsonpath="*) printf '10.42.0.7' ;;
        *"get pod $FIXTURE_VALIDATOR_POD -o json") validator_pod_json ;;
        *"exec $FIXTURE_VALIDATOR_POD -- cat /data/.avalanchego/configs/subnets/$FIXTURE_SUBNET_ID.json")
            [[ "$SC_PRIVACY" == file ]] || return 1
            printf '{"validatorOnly":true,"allowedNodes":["NodeID-FixturePermanentIdentity"]}'
            ;;
        *"exec $FIXTURE_VALIDATOR_POD -- cat /etc/avalanchego/subnets/$FIXTURE_SUBNET_ID.json")
            [[ "$SC_PRIVACY" == dir ]] || return 1
            printf '{"validatorOnly":true,"allowedNodes":["NodeID-FixturePermanentIdentity"]}'
            ;;
        *'port-forward --address'*)
            # A recorded, genuinely long-lived child, so a leaked forward is
            # observable in the parent shell after the doctor returns.
            [[ -n "$SC_PF_WITNESS" ]] || return 0
            exec /bin/sh -c 'echo $$ >>"$1"; exec sleep 300' _ "$SC_PF_WITNESS"
            ;;
        *'port-forward'*) return 0 ;;
        *'--check-keystore'*) [[ "$SC_KEYSTORE_OK" == true ]] ;;
        *'--check-db /data/backups/relayer.db.bak'*) [[ "$SC_HOT_BACKUP" == valid ]] ;;
        *'test -f /data/backups/relayer.db.bak'*) [[ "$SC_HOT_BACKUP" == corrupt ]] ;;
        *'test -d /data/backups'*) return 0 ;;
        *'cd /data/backups'*) archive_exec_output ;;
        *SAFE_TX_SERVICE_URL*) [[ "$SC_TXS_OK" == true ]] ;;
        *'127.0.0.1:8081/keys'*)
            [[ "$SC_FUNDING" == ok ]] && printf '{"fundedFloat":true,"fundedGas":true}' \
                || printf '{"fundedFloat":false,"fundedGas":true}'
            ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------- run helpers
DOCTOR_OUTPUT=""
DOCTOR_STATUS=0
CASE_NAME=""
DOCTOR_TMP="$FIXTURE_DIR/doctor-tmp"

run_doctor() {
    CASE_NAME="$1"
    shift
    # The doctor stages the preflight's large RPC responses, its captured preflight
    # stderr, and its port-forward pid under TMP_DIR, so give every case a fresh one
    # inside this suite's workspace instead of leaving a mktemp -d behind per run.
    rm -rf "$DOCTOR_TMP"
    mkdir -p "$DOCTOR_TMP"
    set +e
    DOCTOR_OUTPUT="$(
        for assignment in "$@"; do export "${assignment?}"; done
        # Every assignment below is consumed by the sourced doctor, not by this file.
        # shellcheck disable=SC2034
        {
            ROOT_DIR="${SC_WS:-$FIXTURE_DIR/ws}"
            K8S_DIR="$ROOT_DIR"
            RELAYER_VERSION="$FIXTURE_VERSION"
            TMP_DIR="$DOCTOR_TMP"
            NAMESPACE=""; CONTEXT=""; RPC_SERVICE=""; RPC_RELEASE=""
            VALIDATOR_RELEASE=""; OPERATOR_IDENTITY=""
        }
        doctor_k8s "$SC_SCOPE" 2>&1
    )"
    DOCTOR_STATUS=$?
    set -e
}

expect_status() {
    [[ "$DOCTOR_STATUS" -eq "$1" ]] || \
        fail "$CASE_NAME returned $DOCTOR_STATUS, expected $1: $DOCTOR_OUTPUT"
}

expect_result() {
    local id actual
    if ! grep -Fq "$1" <<<"$DOCTOR_OUTPUT"; then
        id="$(awk '{print $2}' <<<"$1")"
        actual="$(grep -F " $id | " <<<"$DOCTOR_OUTPUT" | tr '\n' ';' || true)"
        fail "$CASE_NAME did not report '$1'; $id was reported as: ${actual:-<absent>}"
    fi
}

refute_result() {
    if grep -Fq "$1" <<<"$DOCTOR_OUTPUT"; then
        fail "$CASE_NAME unexpectedly reported '$1': $DOCTOR_OUTPUT"
    fi
}

expect_once() {
    local count
    count="$(grep -cE "^(PASS|WARN|FAIL|SKIP) ${1//./\\.} \|" <<<"$DOCTOR_OUTPUT" || true)"
    [[ "$count" -eq 1 ]] || fail "$CASE_NAME emitted $1 $count time(s), expected exactly one"
}

# The recorded process is never a child of this shell (it is orphaned when the
# subshell that spawned it exits), so kill -0 is a truthful liveness test rather
# than a zombie lookup. A leaked forward stays alive for its whole sleep, so a
# short bounded wait separates "already reaped" from "still proxying the L1 RPC".
expect_reaped() {
    local pid="$1" description="$2"
    for _ in $(seq 1 20); do
        kill -0 "$pid" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    kill "$pid" >/dev/null 2>&1 || true
    fail "$description (pid $pid is still running)"
}

# =============================================================================
# 1. The shared result formatter and the doctor_finish exit-code contract.
#    RELAYER_DOCTOR_FIXTURE short-circuits doctor_k8s, so exactly these two cases
#    use it; every case below drives real check logic.
# =============================================================================
run_fixture_case() {
    local name="$1" expected_exit="$2" level="$3" id="$4" summary="$5"
    local fixture="$FIXTURE_DIR/$name.fixture" output status
    printf '%s|%s|%s|%s\n' "$level" "$id" "$summary" "fixture remediation for $name" >"$fixture"
    set +e
    output="$(RELAYER_VERSION=v0.1.0-test RELAYER_DOCTOR_FIXTURE="$fixture" "$K8S_SCRIPT" doctor 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq "$expected_exit" ]] || fail "$name returned $status, expected $expected_exit: $output"
    grep -Fq "$level $id | $summary | remediation: fixture remediation for $name" <<<"$output" || \
        fail "$name did not preserve its stable level/id/remediation: $output"
}

run_fixture_case formatter-pass 0 PASS K8S.RUNTIME.READY "installed runtime is ready"
run_fixture_case formatter-blocker 1 FAIL K8S.FUNDING.READY "funding is below threshold"
run_fixture_case formatter-warning 0 WARN K8S.BACKUPS.FRESHNESS "no manual retained backup is recorded"

pipe_output="$(
    bash -c 'source "$1"; doctor_result WARN K8S.CONFIG.BOOTSTRAP "sum|mary" "reme|diation"' _ "$K8S_SCRIPT"
)"
[[ "$pipe_output" == 'WARN K8S.CONFIG.BOOTSTRAP | sum/mary | remediation: reme/diation' ]] || \
    fail "a result carrying the field separator was not sanitised: $pipe_output"

# doctor_k8s takes doctor_vm's scope argument, so it must reject an unknown scope
# the same way instead of silently diagnosing at the wrong severity.
set +e
scope_output="$(bash -c 'source "$1"; doctor_k8s bogus-scope' _ "$K8S_SCRIPT" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "an unsupported doctor scope returned $status, expected 1: $scope_output"
grep -Fq "unsupported Relayer doctor scope 'bogus-scope'" <<<"$scope_output" || \
    fail "an unsupported doctor scope did not name the rejected scope: $scope_output"

# An invalid level returns 2, which the doctor's own set -e turns into an abort
# rather than a silently miscounted result.
set +e
level_output="$(bash -c 'source "$1"; doctor_result BOGUS K8S.RPC.HEALTH summary; doctor_finish' _ "$K8S_SCRIPT" 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "an invalid diagnostic level did not abort the doctor: $level_output"
if grep -Fq 'Relayer doctor found' <<<"$level_output"; then
    fail "an invalid diagnostic level was summarised as a normal doctor run: $level_output"
fi
grep -Fq 'FAIL DOCTOR.INTERNAL.LEVEL' <<<"$level_output" || \
    fail "an invalid diagnostic level was not reported as an internal failure: $level_output"

# k8s_doctor_command derives its check ID from the command name it probes.
set +e
tool_output="$(
    bash -c 'source "$1"; k8s_doctor_command bash Bash; k8s_doctor_command relayer-absent-tool kubectl; doctor_finish' \
        _ "$K8S_SCRIPT" 2>&1
)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "a missing required tool did not block: $tool_output"
grep -Fq 'PASS K8S.TOOL.BASH | bash is available' <<<"$tool_output" || \
    fail "an installed tool was not reported as available: $tool_output"
grep -Fq 'FAIL K8S.TOOL.RELAYER_ABSENT_TOOL | relayer-absent-tool is missing | remediation: run make k8s-relayer-prereqs or install kubectl' \
    <<<"$tool_output" || fail "a missing tool did not produce its derived check ID and remediation: $tool_output"

# The dispatcher's own usage contract.
set +e
"$K8S_SCRIPT" invalid-action >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "an invalid action returned $status, expected usage status 2"
set +e
RELAYER_VERSION=not-a-release "$K8S_SCRIPT" doctor >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "an invalid RELAYER_VERSION returned $status, expected usage status 2"

# =============================================================================
# 2. A wholly healthy installation must produce no blocker and no warning, so no
#    check below can be a false positive on a correct cluster.
# =============================================================================
run_doctor healthy
expect_status 0
expect_result "Relayer doctor found no blockers and 0 warning(s)."
expect_result "PASS K8S.CONTEXT.CURRENT | current context is $FIXTURE_CONTEXT"
expect_result "PASS K8S.IDENTITY.CURRENT | current Kubernetes identity is $FIXTURE_IDENTITY"
expect_result "PASS K8S.NAMESPACE.DISCOVERY | l1-config was found in the current context namespace $FIXTURE_NAMESPACE"
expect_result "PASS K8S.RBAC.EFFECTIVE | all installation and lifecycle capabilities are effective in $FIXTURE_NAMESPACE"
expect_result 'PASS K8S.RBAC.CREATE_PODS_PORTFORWARD | create pods/portforward is allowed'
expect_result 'PASS K8S.L1_CONFIG.METADATA | l1-config contains the required managed-L1 metadata'
expect_result 'PASS K8S.L1_CONFIG.CONSISTENCY | l1.env and l1-config agree'
expect_result 'PASS K8S.WORKLOADS.DISCOVERY | one labeled RPC Service and validator StatefulSet were found'
expect_result 'PASS K8S.RUNTIME.STATE | Relayer is installed with retained Secret and PVC'
expect_result 'PASS K8S.RUNTIME.READY | Relayer StatefulSet has one ready replica'
expect_result 'PASS K8S.STORAGE.PVC | one retained ReadWriteOnce Relayer PVC exists'
expect_result 'PASS K8S.IMAGES.IMMUTABLE | all Relayer pod images use immutable digests'
expect_result 'PASS K8S.ACCESS.PUBLIC_ENDPOINTS | no Relayer NodePort, LoadBalancer, or Ingress exists'
expect_result 'PASS K8S.NETWORK_POLICY.PRESENT | Relayer default-deny NetworkPolicy is present'
expect_result 'PASS K8S.ACCESS.ROLE_BINDING | restricted access RoleBinding has exactly the current user'
expect_result "PASS K8S.RELEASE.AVAILABLE | $FIXTURE_VERSION checksums and immutable image assets are anonymously available"
expect_result 'PASS K8S.RELEASE.INTEGRITY | StatefulSet images and l1-config match the selected published release'
expect_result "PASS K8S.CONFIG.BOOTSTRAP | installed info-rpc-url matches the managed in-cluster Info API http://$FIXTURE_RPC_SERVICE:9650"
expect_result 'PASS K8S.RPC.HEALTH | RPC network, blockchain, EVM chain, and bootstrap state match managed metadata'
expect_result 'PASS K8S.PEERS.VISIBLE | RPC sees every labeled validator peer'
expect_result 'PASS K8S.MANAGER.TOPOLOGY | official PoAManager topology and EOA/Safe ownership are healthy'
expect_result "PASS K8S.PEERS.BOOTSTRAP | http://$FIXTURE_RPC_SERVICE:9650 exposes 2 current Primary Network bootstrap peer(s)"
expect_result "PASS K8S.SAFE.DISCOVERY | PoAManager owner $FIXTURE_POA_OWNER is a Safe served by the discovered safe-txs Service safe-txs"
expect_result 'PASS K8S.SAFE.CONSOLE_ENV | console Safe variables are complete and the configured Transaction Service answers /api/v1/about/'
expect_result 'PASS K8S.KEYS.INTEGRITY | encrypted keystore decrypts inside the daemon container'
expect_result 'PASS K8S.STATE.INTEGRITY | the daemon-opened bbolt state has a structurally valid rolling hot backup'
expect_result 'PASS K8S.FUNDING.READY | P-Chain float and L1 gas addresses meet daemon funding thresholds'
expect_result "PASS K8S.BACKUPS.FRESHNESS | latest retained backup is $FIXTURE_RECENT_BACKUP"
expect_result "PASS K8S.BACKUPS.INTEGRITY | retained backup $FIXTURE_BACKUP_ARCHIVE matches the sha256 recorded in its manifest"

# Every named diagnostic must be emitted exactly once per run.
healthy_ids=(
    K8S.ACCESS.PUBLIC_ENDPOINTS K8S.ACCESS.ROLE_BINDING K8S.BACKUPS.FRESHNESS
    K8S.BACKUPS.INTEGRITY K8S.CONFIG.BOOTSTRAP K8S.CONTEXT.CURRENT K8S.FUNDING.READY
    K8S.IDENTITY.CURRENT K8S.IMAGES.IMMUTABLE K8S.KEYS.INTEGRITY
    K8S.L1_CONFIG.CONSISTENCY K8S.L1_CONFIG.METADATA K8S.MANAGER.TOPOLOGY
    K8S.NAMESPACE.DISCOVERY K8S.NETWORK_POLICY.PRESENT K8S.PEERS.BOOTSTRAP
    K8S.PEERS.VISIBLE K8S.RBAC.EFFECTIVE K8S.RELEASE.AVAILABLE K8S.RELEASE.INTEGRITY
    K8S.RPC.HEALTH K8S.RUNTIME.READY K8S.RUNTIME.STATE K8S.SAFE.CONSOLE_ENV
    K8S.SAFE.DISCOVERY K8S.STATE.INTEGRITY K8S.STORAGE.PVC K8S.WORKLOADS.DISCOVERY
)
for id in "${healthy_ids[@]}"; do
    expect_once "$id"
done
# A renamed, deleted, or untested named diagnostic fails here.
for id in $(grep -oE 'K8S\.[A-Z0-9_]+\.[A-Z0-9_]+' "$K8S_SCRIPT" | sort -u); do
    [[ " ${healthy_ids[*]} " == *" $id "* ]] || \
        fail "$K8S_SCRIPT emits $id, which this suite does not cover"
done

# =============================================================================
# 3. Context and namespace discovery: current context first, the documented
#    cluster-wide fallback, and each documented failure.
# =============================================================================
run_doctor no-context SC_CONTEXT=
expect_status 1
expect_result 'FAIL K8S.CONTEXT.CURRENT | no current Kubernetes context is configured'

run_doctor no-identity SC_IDENTITY=
expect_status 1
expect_result 'FAIL K8S.IDENTITY.CURRENT | current Kubernetes identity could not be resolved'

run_doctor namespace-fallback SC_NS=fallback
expect_status 0
expect_result 'PASS K8S.NAMESPACE.DISCOVERY | l1-config was uniquely discovered in namespace fallback-l1'

run_doctor namespace-denied SC_NS=denied
expect_status 1
expect_result "FAIL K8S.NAMESPACE.DISCOVERY | l1-config is absent from current namespace 'default' and cluster-wide discovery is not permitted"
# Namespace discovery is the gate for the rest of the doctor, so it must degrade
# to SKIP rather than emitting invented results.
expect_result 'SKIP K8S.RBAC.EFFECTIVE | effective namespace permissions were not checked'
expect_result 'SKIP K8S.L1_CONFIG.METADATA | managed L1 metadata was not checked'
expect_result 'SKIP K8S.WORKLOADS.DISCOVERY | RPC and validator resources were not checked'
expect_result 'SKIP K8S.RUNTIME.STATE | Relayer workload state was not checked'

run_doctor namespace-multiple SC_NS=fallback SC_ALLNS=multiple
expect_status 1
expect_result 'FAIL K8S.NAMESPACE.DISCOVERY | multiple l1-config ConfigMaps exist in the current context'

run_doctor namespace-zero SC_NS=fallback SC_ALLNS=zero
expect_status 1
expect_result 'FAIL K8S.NAMESPACE.DISCOVERY | no l1-config ConfigMap exists in the current context'

# The lifecycle path's discovery has a distinct authorized-but-failed branch.
set +e
discovery_output="$(
    SC_NS=fallback SC_ALLNS=fail bash -c '
        source "$1"
        NAMESPACE=""
        kubectl() {
            case "$*" in
                "config current-context") printf test-context ;;
                *"config view --minify"*) printf default ;;
                *"get configmap l1-config") return 1 ;;
                *"auth can-i list configmaps --all-namespaces"*) printf yes ;;
                "get configmaps --all-namespaces -o json") return 1 ;;
                *) return 1 ;;
            esac
        }
        discover_namespace
    ' _ "$K8S_SCRIPT" 2>&1
)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "authorized-but-failed namespace discovery returned $status, expected 1: $discovery_output"
grep -Fq 'cluster-wide ConfigMap discovery was authorized but failed' <<<"$discovery_output" || \
    fail "authorized-but-failed namespace discovery did not explain itself: $discovery_output"

# =============================================================================
# 4. Effective RBAC, including a single denied verb.
# =============================================================================
run_doctor rbac-denied "SC_RBAC_DENY=create pods/portforward"
expect_status 1
expect_result "FAIL K8S.RBAC.CREATE_PODS_PORTFORWARD | create pods/portforward is denied in $FIXTURE_NAMESPACE"
expect_result 'FAIL K8S.RBAC.EFFECTIVE | 1 required namespace capabilities are denied'
refute_result 'PASS K8S.RBAC.CREATE_PODS_PORTFORWARD'

run_doctor rbac-denied-dotted "SC_RBAC_DENY=delete statefulsets.apps"
expect_status 1
expect_result "FAIL K8S.RBAC.DELETE_STATEFULSETS_APPS | delete statefulsets.apps is denied in $FIXTURE_NAMESPACE"

# =============================================================================
# 5. Workload and runtime state: absent, present but not ready, ready.
# =============================================================================
run_doctor workload-absent SC_STS=false SC_SECRET=false SC_PVC=0 SC_LAST_BACKUP=
expect_status 0
expect_result 'PASS K8S.RUNTIME.STATE | Relayer is not installed and is ready for a fresh install'
expect_result 'SKIP K8S.RUNTIME.READY | runtime readiness does not apply while the workload is absent'
expect_result 'SKIP K8S.IMAGES.IMMUTABLE | installed image references do not apply while the workload is absent'
expect_result 'SKIP K8S.NETWORK_POLICY.PRESENT | NetworkPolicy does not apply while the workload is absent'
expect_result 'SKIP K8S.ACCESS.ROLE_BINDING | restricted access RoleBinding does not apply while the workload is absent'
expect_result 'SKIP K8S.RELEASE.INTEGRITY | installed release integrity does not apply while the workload is absent'
expect_result 'SKIP K8S.CONFIG.BOOTSTRAP | installed bootstrap configuration does not apply while the workload is absent'
expect_result 'SKIP K8S.SAFE.CONSOLE_ENV | Safe console variables do not apply while the Relayer workload is absent'
expect_result 'SKIP K8S.KEYS.INTEGRITY | keystore integrity requires a ready workload'
expect_result 'SKIP K8S.STATE.INTEGRITY | state integrity requires a ready workload'
expect_result 'SKIP K8S.FUNDING.READY | funding readiness requires a ready workload'
expect_result 'SKIP K8S.BACKUPS.FRESHNESS | backup freshness does not apply before installation'
expect_result 'SKIP K8S.BACKUPS.INTEGRITY | retained backup verification does not apply before installation'
expect_result 'PASS K8S.STORAGE.PVC | the managed RPC PVC proves a bound ReadWriteOnce StorageClass is available'

run_doctor workload-reinstallable SC_STS=false SC_SECRET=true SC_PVC=1
expect_status 0
expect_result 'PASS K8S.RUNTIME.STATE | Relayer workload is removed and retained Secret/PVC are ready for reinstall'

run_doctor workload-partial SC_STS=true SC_SECRET=false SC_PVC=1
expect_status 1
expect_result 'FAIL K8S.RUNTIME.STATE | Relayer workload, Secret, and PVC form a partial installation'

# Section 11 pairs this state with install scope, where the reapply repairs it.
run_doctor workload-not-ready SC_READY=0
expect_status 1
expect_result 'FAIL K8S.RUNTIME.READY | Relayer StatefulSet readiness is 0/1 | remediation: inspect make k8s-relayer-logs and repair readiness before validator operations'
expect_result 'WARN K8S.STATE.INTEGRITY | the installed daemon is not ready enough to verify its rolling bbolt hot backup'
expect_result 'WARN K8S.BACKUPS.INTEGRITY | the newest retained backup could not be verified while the Relayer pod is not ready'
expect_result 'WARN K8S.SAFE.CONSOLE_ENV | console Safe variables are complete, but the Transaction Service could not be probed from an unready console container'
expect_result 'SKIP K8S.KEYS.INTEGRITY | keystore integrity requires a ready workload'
expect_result 'SKIP K8S.FUNDING.READY | funding readiness requires a ready workload'

run_doctor workloads-missing SC_WORKLOADS=missing
expect_status 1
expect_result 'FAIL K8S.WORKLOADS.DISCOVERY | expected one labeled RPC Service and validator StatefulSet; found 0 and 0'
expect_result 'SKIP K8S.RPC.HEALTH | RPC health was not checked because discovery metadata or operator tools are incomplete'
expect_result 'SKIP K8S.PEERS.VISIBLE | peer visibility was not checked'
expect_result 'SKIP K8S.MANAGER.TOPOLOGY | manager topology was not checked'
expect_result 'SKIP K8S.PEERS.BOOTSTRAP | Primary Network bootstrap eligibility was not checked'
expect_result 'SKIP K8S.SAFE.DISCOVERY | EOA/Safe ownership was not checked'
expect_result 'SKIP K8S.SAFE.CONSOLE_ENV | installed Safe console variables were not checked'

# =============================================================================
# 6. Image immutability, release availability, l1.env consistency, bootstrap URL.
# =============================================================================
# A mutable tag is also release drift, and section 11 pairs both with install scope.
run_doctor images-mutable SC_IMAGES=tag
expect_status 1
expect_result 'FAIL K8S.IMAGES.IMMUTABLE | 1 Relayer pod image reference(s) are mutable | remediation: reapply the release using make k8s-relayer-upgrade'
expect_result "FAIL K8S.RELEASE.INTEGRITY | StatefulSet image digests, l1-config metadata, or selected version has drifted | remediation: run make k8s-relayer-upgrade RELAYER_VERSION=$FIXTURE_VERSION"
refute_result 'PASS K8S.IMAGES.IMMUTABLE'

run_doctor release-unavailable SC_RELEASE=missing
expect_status 1
expect_result "FAIL K8S.RELEASE.AVAILABLE | $FIXTURE_VERSION release metadata is unavailable or mutable"

run_doctor l1-env-mismatch "SC_WS=$FIXTURE_DIR/ws-mismatch"
expect_status 1
expect_result 'FAIL K8S.L1_CONFIG.CONSISTENCY | l1.env and l1-config differ for: CHAIN_NAME'

run_doctor l1-env-absent "SC_WS=$FIXTURE_DIR/ws-empty"
expect_status 1
expect_result 'FAIL K8S.L1_CONFIG.CONSISTENCY | generated l1.env is missing from the Avalanche Deploy workspace'
expect_result 'SKIP K8S.RPC.HEALTH | RPC health was not checked because discovery metadata or operator tools are incomplete'

run_doctor config-loopback SC_INFO_URL=http://127.0.0.1:41234
expect_status 0
expect_result 'WARN K8S.CONFIG.BOOTSTRAP | installed info-rpc-url http://127.0.0.1:41234 is a loopback endpoint'

run_doctor config-drift SC_INFO_URL=http://other-rpc:9650
expect_status 0
expect_result 'WARN K8S.CONFIG.BOOTSTRAP | installed info-rpc-url http://other-rpc:9650 differs from the managed'
expect_result 'remediation: run make k8s-relayer to reapply the managed configuration'

run_doctor config-unreadable SC_INFO_URL=
expect_status 0
expect_result 'WARN K8S.CONFIG.BOOTSTRAP | the installed daemon config.json in ConfigMap relayer-config has no readable info-rpc-url'

# =============================================================================
# 7. Manager topology and PoAManager owner classification. These run the real
#    preflight over the real rpc_call/evm_call/contract_call chain, so the two
#    defects fixed in this change are covered where they live.
# =============================================================================
# Drives the real preflight in a child shell, so a case that only concerns the
# preflight itself does not pay for a whole doctor run. Knobs are passed as
# NAME=value assignments, exactly as run_doctor takes them.
run_preflight() {
    CASE_NAME="preflight-$1"
    shift
    set +e
    DOCTOR_OUTPUT="$(
        for assignment in "$@"; do export "${assignment?}"; done
        bash -c '
            source "$1"
            . "$2"
            NAMESPACE="'"$FIXTURE_NAMESPACE"'"
            L1_ENV="$3"
            start_rpc_forward() { RPC_PORT=39999; }
            preflight
            printf "OWNER_TYPE=%s POA_OWNER=%s\n" "$OWNER_TYPE" "$POA_OWNER"
        ' _ "$K8S_SCRIPT" "$FIXTURE_DIR/stubs.sh" "$FIXTURE_DIR/ws/l1.env" 2>&1
    )"
    DOCTOR_STATUS=$?
    set -e
}

# The stubs are shared with the child shells that call preflight directly.
{
    declare -f helm
    declare -f release_curl
    declare -f curl
    declare -f kubectl
    declare -f peers_json
    declare -f validator_pod_json
    declare -f l1_config_json
    declare -f statefulset_json
    declare -f archive_exec_output
    declare -f backup_manifest_json
    declare -f address_word
    declare -f uint_word
    for name in FIXTURE_CONTEXT FIXTURE_NAMESPACE FIXTURE_IDENTITY FIXTURE_RPC_SERVICE \
        FIXTURE_RPC_RELEASE FIXTURE_VALIDATOR_RELEASE FIXTURE_VALIDATOR_POD \
        FIXTURE_VALIDATOR_NODE_ID FIXTURE_SUBNET_ID FIXTURE_CHAIN_ID FIXTURE_CHAIN_NAME \
        FIXTURE_EVM_CHAIN_ID FIXTURE_POA_MANAGER FIXTURE_VALIDATOR_MANAGER FIXTURE_POA_OWNER \
        FIXTURE_VERSION FIXTURE_RELAYERD_IMAGE FIXTURE_CONSOLE_IMAGE FIXTURE_BACKUP_ARCHIVE \
        FIXTURE_GOOD_SHA FIXTURE_BAD_SHA FIXTURE_LARGE_PEERS FIXTURE_LARGE_VALIDATORS \
        FIXTURE_LARGE_OTHER_VALIDATORS FIXTURE_LARGE_SUBNET_VALIDATORS FIXTURE_LARGE_BLOCKCHAINS; do
        printf '%s=%q\n' "$name" "${!name}"
    done
    printf ': "${SC_CONTEXT:=%s}"\n' "$FIXTURE_CONTEXT"
    cat <<'DEFAULTS'
: "${SC_NS:=current}"
: "${SC_ALLNS:=one}"
: "${SC_IDENTITY:=operator@example.test}"
: "${SC_RBAC_DENY:=}"
: "${SC_WORKLOADS:=ok}"
: "${SC_STS:=true}"
: "${SC_SECRET:=true}"
: "${SC_PVC:=1}"
: "${SC_READY:=1}"
: "${SC_IMAGES:=digest}"
: "${SC_RELEASE:=ok}"
: "${SC_INFO_URL:=}"
: "${SC_OWNER:=safe}"
: "${SC_PEERS:=visible}"
: "${SC_ELIGIBLE:=2}"
: "${SC_SAFE:=present}"
: "${SC_CONSOLE_ENV:=full}"
: "${SC_TXS_OK:=true}"
: "${SC_KEYSTORE_OK:=true}"
: "${SC_HOT_BACKUP:=valid}"
: "${SC_FUNDING:=ok}"
: "${SC_LAST_BACKUP:=}"
: "${SC_ARCHIVE:=valid}"
: "${SC_PAYLOAD:=small}"
: "${SC_PRIVACY:=none}"
: "${SC_PF_WITNESS:=}"
DEFAULTS
} >"$FIXTURE_DIR/stubs.sh"

run_preflight safe SC_OWNER=safe
[[ "$DOCTOR_STATUS" -eq 0 ]] || fail "$CASE_NAME failed: $DOCTOR_OUTPUT"
grep -Fq "OWNER_TYPE=Safe POA_OWNER=$FIXTURE_POA_OWNER" <<<"$DOCTOR_OUTPUT" || \
    fail "$CASE_NAME did not classify a Safe owner: $DOCTOR_OUTPUT"

run_preflight eoa SC_OWNER=eoa
[[ "$DOCTOR_STATUS" -eq 0 ]] || fail "$CASE_NAME failed: $DOCTOR_OUTPUT"
grep -Fq "OWNER_TYPE=EOA POA_OWNER=$FIXTURE_POA_OWNER" <<<"$DOCTOR_OUTPUT" || \
    fail "$CASE_NAME did not classify an EOA owner: $DOCTOR_OUTPUT"

# A renounced PoAManager owner leaves no authority able to approve validator
# changes, so it must never be accepted as a supported EOA.
run_preflight zero SC_OWNER=zero
[[ "$DOCTOR_STATUS" -eq 1 ]] || fail "$CASE_NAME returned $DOCTOR_STATUS, expected 1: $DOCTOR_OUTPUT"
grep -Fq 'is the zero address; a renounced owner leaves no authority' <<<"$DOCTOR_OUTPUT" || \
    fail "$CASE_NAME did not reject a renounced owner: $DOCTOR_OUTPUT"
refute_result 'OWNER_TYPE=EOA'

# An unanswered owner bytecode read must not fall through to the EOA default and
# silently downgrade a Safe-owned L1.
run_preflight unanswered SC_OWNER=unanswered
[[ "$DOCTOR_STATUS" -eq 1 ]] || fail "$CASE_NAME returned $DOCTOR_STATUS, expected 1: $DOCTOR_OUTPUT"
grep -Fq 'did not answer eth_getCode for PoAManager owner' <<<"$DOCTOR_OUTPUT" || \
    fail "$CASE_NAME did not reject an unanswered owner lookup: $DOCTOR_OUTPUT"
refute_result 'OWNER_TYPE=EOA'

run_preflight rpc-error SC_OWNER=rpc-error
[[ "$DOCTOR_STATUS" -eq 1 ]] || fail "$CASE_NAME returned $DOCTOR_STATUS, expected 1: $DOCTOR_OUTPUT"
grep -Fq 'RPC call eth_getCode returned' <<<"$DOCTOR_OUTPUT" || \
    fail "$CASE_NAME did not surface the JSON-RPC error: $DOCTOR_OUTPUT"
refute_result 'OWNER_TYPE=EOA'

run_preflight not-safe SC_OWNER=not-safe
[[ "$DOCTOR_STATUS" -eq 1 ]] || fail "$CASE_NAME returned $DOCTOR_STATUS, expected 1: $DOCTOR_OUTPUT"
grep -Fq 'is a contract but not a compatible Safe' <<<"$DOCTOR_OUTPUT" || \
    fail "$CASE_NAME did not reject an incompatible contract owner: $DOCTOR_OUTPUT"

# The same defects seen through the doctor: a preflight failure blocks and every
# dependent classification degrades to SKIP rather than claiming an EOA. The cause
# also has to survive into the result. Every one of these used to collapse into one
# opaque K8S.RPC.HEALTH blocker whose remediation was the installer this blocker
# prevents, so each cause is asserted here and refuted for the other causes: three
# different broken clusters must not read identically to the operator.
for owner in zero unanswered rpc-error; do
    case "$owner" in
        zero)
            expected_reason='PoAManager owner 0x0000000000000000000000000000000000000000 is the zero address'
            other_reasons=('did not answer eth_getCode' 'RPC call eth_getCode returned') ;;
        unanswered)
            expected_reason="the L1 RPC did not answer eth_getCode for PoAManager owner $FIXTURE_POA_OWNER"
            other_reasons=('is the zero address' 'RPC call eth_getCode returned') ;;
        rpc-error)
            expected_reason='RPC call eth_getCode returned: {"code":-32000,"message":"execution reverted"}'
            other_reasons=('is the zero address' 'is a contract but not a compatible Safe') ;;
    esac
    run_doctor "owner-$owner" "SC_OWNER=$owner"
    expect_status 1
    expect_result "FAIL K8S.RPC.HEALTH | RPC, peer, or manager preflight failed: $expected_reason"
    expect_result 'remediation: repair the reported preflight cause on the managed L1, then rerun make k8s-relayer-doctor'
    # The remediation may never be the installer this same blocker stops.
    refute_result 'remediation: run make k8s-relayer for detailed preflight output'
    for other_reason in "${other_reasons[@]}"; do
        refute_result "$other_reason"
    done
    expect_result 'SKIP K8S.MANAGER.TOPOLOGY | manager topology was not independently confirmed'
    expect_result 'SKIP K8S.SAFE.DISCOVERY | EOA/Safe ownership was not independently confirmed'
    expect_result 'SKIP K8S.PEERS.VISIBLE | peer visibility was not independently confirmed'
    refute_result 'is a supported EOA'
done

run_doctor owner-eoa SC_OWNER=eoa
expect_status 0
expect_result "PASS K8S.SAFE.DISCOVERY | PoAManager owner $FIXTURE_POA_OWNER is a supported EOA"
expect_result 'SKIP K8S.SAFE.CONSOLE_ENV | Safe console variables do not apply to an EOA-owned PoAManager'

# A validator peer the RPC node cannot see fails the real peer-visibility logic,
# and with no evidence of protocol privacy the refusal names the causes that can
# actually apply. It must not send the operator back to make k8s-l1-configure,
# which cannot authorize a protocol-private validator (see section 13).
run_doctor peers-missing SC_PEERS=missing
expect_status 1
expect_result "FAIL K8S.RPC.HEALTH | RPC, peer, or manager preflight failed: RPC node '$FIXTURE_RPC_SERVICE' cannot see validator peer '$FIXTURE_VALIDATOR_NODE_ID'"
expect_result 'confirm the validator finished bootstrapping and that nothing blocks P2P port 9651'
expect_result 'If this L1 is protocol-private (validatorOnly with allowedNodes), the Kubernetes Relayer path does not support it'
refute_result 'rerun make k8s-l1-configure and wait for peering'
refute_result 'enforces protocol privacy'
refute_result 'PASS K8S.PEERS.VISIBLE'

run_doctor bootstrap-none SC_ELIGIBLE=0
expect_status 1
expect_result "FAIL K8S.PEERS.BOOTSTRAP | http://$FIXTURE_RPC_SERVICE:9650 exposes no peers that are current Primary Network validators"

# =============================================================================
# 8. Safe discovery and the Safe console environment.
# =============================================================================
run_doctor safe-absent SC_SAFE=absent
expect_status 1
expect_result "FAIL K8S.SAFE.DISCOVERY | PoAManager owner $FIXTURE_POA_OWNER is a Safe, but no unique Avalanche Deploy Safe release with a safe-txs Service was discovered in $FIXTURE_NAMESPACE"

run_doctor safe-multiple SC_SAFE=multiple
expect_status 1
expect_result 'FAIL K8S.SAFE.DISCOVERY | PoAManager owner'
refute_result 'PASS K8S.SAFE.DISCOVERY'

run_doctor safe-no-txs SC_SAFE=no-txs
expect_status 1
expect_result 'FAIL K8S.SAFE.DISCOVERY | PoAManager owner'

# A Safe-owned console that lost SAFE_ADDRESS, SAFE_TX_SERVICE_URL, or SAFE_UI_URL
# cannot propose any validator change, so operations scope must block on it exactly
# as VM.SAFE.CONSOLE_ENV does. Section 11 pairs each of these with install scope.
run_doctor safe-console-env-absent SC_CONSOLE_ENV=none
expect_status 1
expect_result 'FAIL K8S.SAFE.CONSOLE_ENV | installed Safe-owned console container is missing required Safe integration variables (present: none)'
expect_result 'remediation: run make k8s-relayer to reapply the managed Safe integration'
refute_result 'WARN K8S.SAFE.CONSOLE_ENV'

run_doctor safe-console-env-partial SC_CONSOLE_ENV=partial
expect_status 1
expect_result 'FAIL K8S.SAFE.CONSOLE_ENV | installed Safe-owned console container is missing required Safe integration variables (present: SAFE_ADDRESS,SAFE_TX_SERVICE_URL)'
refute_result 'WARN K8S.SAFE.CONSOLE_ENV'

run_doctor safe-txs-down SC_TXS_OK=false
expect_status 1
expect_result 'FAIL K8S.SAFE.CONSOLE_ENV | console Safe variables are complete, but the configured Transaction Service did not answer /api/v1/about/'

# =============================================================================
# 9. Funding readiness, keystore and state integrity.
# =============================================================================
run_doctor funding-low SC_FUNDING=low
expect_status 1
expect_result 'FAIL K8S.FUNDING.READY | one or both public Relayer funding addresses are below threshold | remediation: fund RELAYER_PCHAIN_ADDRESS and RELAYER_EVM_ADDRESS from l1-config'
refute_result 'PASS K8S.FUNDING.READY'

run_doctor keystore-broken SC_KEYSTORE_OK=false
expect_status 1
expect_result 'FAIL K8S.KEYS.INTEGRITY | encrypted keystore integrity check failed'

run_doctor hot-backup-corrupt SC_HOT_BACKUP=corrupt
expect_status 1
expect_result 'FAIL K8S.STATE.INTEGRITY | the rolling bbolt hot backup failed its read-only integrity check'

run_doctor hot-backup-absent SC_HOT_BACKUP=absent
expect_status 0
expect_result 'WARN K8S.STATE.INTEGRITY | relayerd opened the live database but its first rolling hot backup is not available yet'

# =============================================================================
# 10. Backup freshness and retained-archive integrity.
# =============================================================================
run_doctor backup-stale "SC_LAST_BACKUP=$FIXTURE_STALE_BACKUP"
expect_status 0
expect_result "WARN K8S.BACKUPS.FRESHNESS | latest retained backup metadata is older than seven days: $FIXTURE_STALE_BACKUP"

run_doctor backup-unrecorded SC_LAST_BACKUP=
expect_status 0
expect_result 'WARN K8S.BACKUPS.FRESHNESS | no manual retained backup is recorded'

run_doctor archive-mismatch SC_ARCHIVE=mismatch
expect_status 1
expect_result "FAIL K8S.BACKUPS.INTEGRITY | retained backup $FIXTURE_BACKUP_ARCHIVE and its manifest checksum do not match"
refute_result 'PASS K8S.BACKUPS.INTEGRITY'

run_doctor archive-nomanifest SC_ARCHIVE=nomanifest
expect_status 1
expect_result "FAIL K8S.BACKUPS.INTEGRITY | retained backup $FIXTURE_BACKUP_ARCHIVE has no manifest recording its checksum"

run_doctor archive-none SC_ARCHIVE=none
expect_status 0
expect_result 'WARN K8S.BACKUPS.INTEGRITY | no retained manual backup archive was found in the Relayer PVC'

# =============================================================================
# 11. Install versus operations scope. install_relayer runs the doctor as its own
#     gate, so every state a reapply is meant to repair has to warn there while
#     still blocking at operations scope; otherwise make k8s-relayer refuses to fix
#     the drift its own remediation names. Each case below is a cluster state whose
#     operations-scope blocker is asserted in the section named beside it, so the
#     pair is what proves the downgrade is scope-dependent rather than a weakening.
# =============================================================================
run_doctor scope-install-healthy SC_SCOPE=install
expect_status 0
expect_result 'Relayer doctor found no blockers and 0 warning(s).'
# A downgrade that leaks into a healthy run, or a duplicated result, fails here.
for id in "${healthy_ids[@]}"; do
    expect_once "$id"
done

# K8S.RUNTIME.READY, blocking in section 5 (workload-not-ready).
run_doctor scope-install-not-ready SC_SCOPE=install SC_READY=0
expect_status 0
expect_result 'WARN K8S.RUNTIME.READY | Relayer StatefulSet readiness is 0/1 | remediation: this install/reapply will render configuration and restart the runtime'
refute_result 'FAIL K8S.RUNTIME.READY'

# K8S.IMAGES.IMMUTABLE and K8S.RELEASE.INTEGRITY, blocking in section 6
# (images-mutable). A mutable tag is the most common release drift, so the reapply
# has to survive it for the K8S.RELEASE.INTEGRITY downgrade to mean anything.
run_doctor scope-install-image-drift SC_SCOPE=install SC_IMAGES=tag
expect_status 0
expect_result 'WARN K8S.IMAGES.IMMUTABLE | 1 Relayer pod image reference(s) are mutable | remediation: this install/reapply will restore the verified pinned digests'
expect_result 'WARN K8S.RELEASE.INTEGRITY | StatefulSet image digests, l1-config metadata, or selected version has drifted | remediation: this install/reapply will restore the verified pinned artifacts'
refute_result 'FAIL K8S.IMAGES.IMMUTABLE'
refute_result 'FAIL K8S.RELEASE.INTEGRITY'

# K8S.FUNDING.READY, blocking in section 9 (funding-low). A fresh install cannot
# have funded wallets yet, so this is the check that would have made the first
# install of every L1 impossible.
run_doctor scope-install-funding SC_SCOPE=install SC_FUNDING=low
expect_status 0
expect_result 'WARN K8S.FUNDING.READY | one or both public Relayer funding addresses are below threshold | remediation: complete the install/reapply, then fund the addresses printed by make k8s-relayer-status'
refute_result 'FAIL K8S.FUNDING.READY'

# Both K8S.SAFE.CONSOLE_ENV blockers from section 8: variables the reapply
# re-renders, and a Transaction Service the reapply reconnects.
run_doctor scope-install-console-env-absent SC_SCOPE=install SC_CONSOLE_ENV=none
expect_status 0
expect_result 'WARN K8S.SAFE.CONSOLE_ENV | installed Safe-owned console container is missing required Safe integration variables (present: none) | remediation: this install/reapply will render SAFE_TX_SERVICE_URL, SAFE_UI_URL, and SAFE_ADDRESS'
refute_result 'FAIL K8S.SAFE.CONSOLE_ENV'

run_doctor scope-install-txs-down SC_SCOPE=install SC_TXS_OK=false
expect_status 0
expect_result "WARN K8S.SAFE.CONSOLE_ENV | console Safe variables are complete, but the configured Transaction Service did not answer /api/v1/about/ | remediation: complete the install/reapply, then repair the Safe Transaction Service in $FIXTURE_NAMESPACE"
refute_result 'FAIL K8S.SAFE.CONSOLE_ENV'

# K8S.CONFIG.BOOTSTRAP warns at both scopes (section 6, config-drift), but at
# install scope this run is the repair, so the remediation must not send the
# operator back to the command they are already running.
run_doctor scope-install-config-drift SC_SCOPE=install SC_INFO_URL=http://other-rpc:9650
expect_status 0
expect_result 'WARN K8S.CONFIG.BOOTSTRAP | installed info-rpc-url http://other-rpc:9650 differs from the managed'
expect_result 'remediation: this install/reapply will render the managed in-cluster Info API'
refute_result 'remediation: run make k8s-relayer to reapply the managed configuration'

# The deliberate non-member of the downgrade set: an unusable L1 RPC or manager
# topology blocks at both scopes, because install_relayer runs this same preflight
# seconds later and would die on it anyway, as VM.PREFLIGHT.REMOTE does.
run_doctor scope-install-rpc-health SC_SCOPE=install SC_OWNER=zero
expect_status 1
expect_result 'FAIL K8S.RPC.HEALTH | RPC, peer, or manager preflight failed: PoAManager owner 0x0000000000000000000000000000000000000000 is the zero address'
refute_result 'WARN K8S.RPC.HEALTH'

# =============================================================================
# 12. Protocol privacy. A validatorOnly validator is invisible to the RPC node by
#     design, and neither make k8s-l1-configure nor waiting can change that: only
#     adding the NodeID to allowedNodes can, which this path does not implement. So
#     the refusal has to name the Kubernetes limitation and point at the path that
#     does support it. AvalancheGo reads validatorOnly from --subnet-config-content
#     or from <subnet-config-dir>/<subnetId>.json, so all three routes are covered.
# =============================================================================
for privacy in content dir file; do
    run_preflight "protocol-private-$privacy" SC_OWNER=safe SC_PEERS=missing "SC_PRIVACY=$privacy"
    [[ "$DOCTOR_STATUS" -eq 1 ]] || \
        fail "$CASE_NAME returned $DOCTOR_STATUS, expected 1: $DOCTOR_OUTPUT"
    expect_result "validator pod '$FIXTURE_VALIDATOR_POD' ($FIXTURE_VALIDATOR_NODE_ID) enforces protocol privacy (validatorOnly) for subnet '$FIXTURE_SUBNET_ID'"
    expect_result 'the Kubernetes Relayer path does not support protocol-private L1s, so install and operate this Relayer with the Terraform/Ansible path (make relayer)'
    refute_result 'rerun make k8s-l1-configure and wait for peering'
    refute_result 'confirm the validator finished bootstrapping'
done

# validatorOnly: false is an ordinary peering failure and must not be reported as a
# protocol-private L1, or the refusal would send working clusters to the VM path.
run_preflight protocol-private-disabled SC_OWNER=safe SC_PEERS=missing SC_PRIVACY=content-public
[[ "$DOCTOR_STATUS" -eq 1 ]] || \
    fail "$CASE_NAME returned $DOCTOR_STATUS, expected 1: $DOCTOR_OUTPUT"
# This helper reaches preflight without discover_workloads, so the RPC Service name
# in the message is empty here; section 7 covers the fully discovered wording.
expect_result "cannot see validator peer '$FIXTURE_VALIDATOR_NODE_ID'"
refute_result 'enforces protocol privacy'

# The same refusal seen through the doctor, which is where an operator meets it.
# Section 7's peers-missing case is the undetected-privacy half of this pair.
run_doctor protocol-private SC_PEERS=missing SC_PRIVACY=content
expect_status 1
expect_result "FAIL K8S.RPC.HEALTH | RPC, peer, or manager preflight failed: validator pod '$FIXTURE_VALIDATOR_POD' ($FIXTURE_VALIDATOR_NODE_ID) enforces protocol privacy (validatorOnly) for subnet '$FIXTURE_SUBNET_ID'"
expect_result 'the Kubernetes Relayer path does not support protocol-private L1s'
refute_result 'rerun make k8s-l1-configure and wait for peering'

# =============================================================================
# 13. Realistically sized RPC responses. A few-hundred-byte peer list makes every
#     assertion above hold no matter how the response reaches jq, which is how a
#     check that passed a multi-megabyte validator set through one argv element
#     stayed green here. These two cases carry Fuji-to-Mainnet sized payloads
#     through info.peers, both platform.getCurrentValidators reads, and
#     platform.getBlockchains, and still demand the right answer.
# =============================================================================
run_doctor large-payload-eligible SC_PAYLOAD=match
expect_status 0
expect_result 'Relayer doctor found no blockers and 0 warning(s).'
expect_result "PASS K8S.PEERS.BOOTSTRAP | http://$FIXTURE_RPC_SERVICE:9650 exposes $FIXTURE_LARGE_ELIGIBLE current Primary Network bootstrap peer(s)"
expect_result 'PASS K8S.RPC.HEALTH | RPC network, blockchain, EVM chain, and bootstrap state match managed metadata'
expect_result 'PASS K8S.PEERS.VISIBLE | RPC sees every labeled validator peer'
expect_result 'PASS K8S.MANAGER.TOPOLOGY | official PoAManager topology and EOA/Safe ownership are healthy'

# The same sizes with a validator set that shares no NodeID with the peer set: the
# intersection is genuinely computed, not merely survived.
run_doctor large-payload-ineligible SC_PAYLOAD=disjoint
expect_status 1
expect_result "FAIL K8S.PEERS.BOOTSTRAP | http://$FIXTURE_RPC_SERVICE:9650 exposes no peers that are current Primary Network validators"
expect_result 'PASS K8S.PEERS.VISIBLE | RPC sees every labeled validator peer'

# =============================================================================
# 14. Port-forward lifetime. The doctor's preflight runs in a command substitution,
#     so the port-forward it starts cannot assign PF_PID here and would outlive the
#     run as an unauthenticated loopback proxy to the L1 RPC. Both the doctor's own
#     reaping and cleanup()'s backstop are exercised with real processes.
# =============================================================================
: >"$PF_WITNESS_FILE"
set +e
(
    export SC_PF_WITNESS="$PF_WITNESS_FILE"
    # shellcheck disable=SC2034
    {
        ROOT_DIR="$FIXTURE_DIR/ws"
        K8S_DIR="$ROOT_DIR"
        RELAYER_VERSION="$FIXTURE_VERSION"
        TMP_DIR="$FIXTURE_DIR/port-forward-tmp"
        NAMESPACE=""; CONTEXT=""; RPC_SERVICE=""; RPC_RELEASE=""
        VALIDATOR_RELEASE=""; OPERATOR_IDENTITY=""
    }
    mkdir -p "$TMP_DIR"
    doctor_k8s
) >"$FIXTURE_DIR/port-forward.out" 2>&1
port_forward_status=$?
set -e
CASE_NAME="port-forward-lifetime"
DOCTOR_OUTPUT="$(cat "$FIXTURE_DIR/port-forward.out")"
DOCTOR_STATUS="$port_forward_status"
expect_status 0
expect_result 'PASS K8S.RPC.HEALTH | RPC network, blockchain, EVM chain, and bootstrap state match managed metadata'
# The RPC Service forward and the validator pod forward are both real here.
forward_count="$(grep -c '^[0-9]' "$PF_WITNESS_FILE" || true)"
[[ "$forward_count" -ge 2 ]] || \
    fail "$CASE_NAME started $forward_count port-forward(s); the RPC Service and validator pod forwards were expected to be real"
while read -r forward_pid; do
    [[ -n "$forward_pid" ]] || continue
    expect_reaped "$forward_pid" "the doctor left a kubectl port-forward running after it returned"
done <"$PF_WITNESS_FILE"

# The backstop for a doctor that dies before its own reaping: cleanup() must find
# the forward through PF_PID_FILE, which is the only channel a forward started in a
# command substitution has back to this shell.
aborted_forward="$(bash -c 'sleep 300 >/dev/null 2>&1 & printf "%s\n" "$!"')"
printf '%s\n' "$aborted_forward" >>"$PF_WITNESS_FILE"
printf '%s\n' "$aborted_forward" >"$FIXTURE_DIR/aborted-forward.pid"
(
    PF_PID_FILE="$FIXTURE_DIR/aborted-forward.pid"
    PF_PID=""; TMP_DIR=""; NAMESPACE=""; BACKUP_REPLICAS=""
    RESTORE_STAGE_CLAIM=""; RESTORE_STAGE_POD=""
    cleanup
)
expect_reaped "$aborted_forward" "cleanup did not kill the port-forward recorded by an aborted doctor run"

echo "Kubernetes Relayer doctor fixtures passed"
