#!/usr/bin/env bash
# Zero-input Kubernetes installation and lifecycle for the Avalanche L1 Relayer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$K8S_DIR")"
# shellcheck source=scripts/shared/relayer-doctor-lib.sh
source "$ROOT_DIR/scripts/shared/relayer-doctor-lib.sh"

ACTION="${1:-install}"
OFFICIAL_RELAYER_REPOSITORY="ava-labs/avalanche-vmc-relayer"
DEFAULT_RELAYER_VERSION_SELECTOR="official-latest"
RELAYER_VERSION="${RELAYER_VERSION:-$DEFAULT_RELAYER_VERSION_SELECTOR}"
RELAYER_PRERELEASE_FALLBACK="${RELAYER_PRERELEASE_FALLBACK:-v0.1.0-rc.8}"
RELAYER_REPOSITORY="${RELAYER_DEVELOPMENT_REPOSITORY:-$OFFICIAL_RELAYER_REPOSITORY}"
RELAYER_DEVELOPMENT_TOKEN="${RELAYER_DEVELOPMENT_TOKEN:-}"
RELAYER_RELEASE="relayer"
RELAYER_SECRET="relayer-runtime"
RELAYER_POD="relayer-0"
UTILITY_IMAGE="docker.io/library/busybox@sha256:9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028"
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
PF_PID_FILE=""
TMP_DIR=""
BACKUP_REPLICAS=""
RESTORE_STAGE_CLAIM=""
RESTORE_STAGE_POD=""
RELAYERD_IMAGE=""
CONSOLE_IMAGE=""
STORAGE_CLASS=""

usage() {
    cat <<USAGE
Usage: $0 {prereqs|doctor|install|access|status|logs|backup|restore|upgrade|remove}

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
    # A port-forward started inside a command substitution cannot assign PF_PID in
    # this shell and its EXIT trap is reset there, so start_rpc_forward publishes
    # the pid to PF_PID_FILE. Without this the doctor's preflight forward outlives
    # every run as an unauthenticated loopback proxy to the L1 RPC.
    local recorded_pid=""
    [[ -z "$PF_PID_FILE" || ! -f "$PF_PID_FILE" ]] || \
        recorded_pid="$(tr -dc '0-9' <"$PF_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$recorded_pid" && "$recorded_pid" != "$PF_PID" ]]; then
        kill "$recorded_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$PF_PID" ]]; then
        kill "$PF_PID" >/dev/null 2>&1 || true
        wait "$PF_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    # The VM restore playbook removes its staged workspace in an always: block, so
    # this is the Kubernetes equivalent: a Ctrl-C during a pod wait, a kubectl or
    # pod-deletion failure, or any die between staging and the apply pod must not
    # leave the extracted node P2P TLS private key on the PVC. It runs before the
    # rescale below so the cleanup pod can still mount the ReadWriteOnce claim, and
    # clean_restore_stage always returns 0, so it cannot mask the original error.
    if [[ -n "$RESTORE_STAGE_CLAIM" && -n "$RESTORE_STAGE_POD" && -n "$NAMESPACE" ]]; then
        clean_restore_stage "$RESTORE_STAGE_POD" "$RESTORE_STAGE_CLAIM" || true
        RESTORE_STAGE_CLAIM=""
    fi
    if [[ -n "$BACKUP_REPLICAS" && -n "$NAMESPACE" ]]; then
        kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas="$BACKUP_REPLICAS" >/dev/null 2>&1 || true
        BACKUP_REPLICAS=""
    fi
    PF_PID=""
}
trap cleanup EXIT
# A signal must end the run: bash resumes an interrupted kubectl wait after the
# handler returns, and resuming a restore whose stage this cleanup just deleted is
# worse than stopping. The EXIT trap then finds every step already done.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
    done
}

validate_release_source() {
    [[ "$RELAYER_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
        die "invalid Relayer release repository: $RELAYER_REPOSITORY"
    if [[ "$RELAYER_REPOSITORY" != "$OFFICIAL_RELAYER_REPOSITORY" || -n "$RELAYER_DEVELOPMENT_TOKEN" ]]; then
        [[ "${RELAYER_DEVELOPMENT:-false}" == "true" ]] || \
            die "repository or authentication overrides require RELAYER_DEVELOPMENT=true and are not part of the supported operator flow"
    fi
}

official_latest_release_tag() {
    local metadata
    metadata="$(release_curl -fsSL --retry 3 --retry-delay 1 \
        "https://api.github.com/repos/$OFFICIAL_RELAYER_REPOSITORY/releases?per_page=100")" || return 1
    jq -er '
      [
        .[] |
        select(.draft == false and .prerelease == false) |
        .tag_name |
        select(type == "string" and test("^v[0-9A-Za-z][0-9A-Za-z.+-]*$"))
      ][0] // ""
    ' <<<"$metadata"
}

resolve_release_version() {
    [[ "$RELAYER_VERSION" == "$DEFAULT_RELAYER_VERSION_SELECTOR" ]] || return 0
    [[ "$RELAYER_REPOSITORY" == "$OFFICIAL_RELAYER_REPOSITORY" ]] || \
        die "$DEFAULT_RELAYER_VERSION_SELECTOR can resolve only from $OFFICIAL_RELAYER_REPOSITORY"

    local stable_version="" release_query_succeeded=false
    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        if stable_version="$(official_latest_release_tag 2>/dev/null)"; then
            release_query_succeeded=true
        fi
    else
        release_query_succeeded=true
    fi
    if [[ "$stable_version" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
        RELAYER_VERSION="$stable_version"
        printf 'Selected latest official production Relayer release: %s\n' "$RELAYER_VERSION" >&2
        return 0
    fi

    [[ "$release_query_succeeded" == true ]] || \
        die "could not query official Relayer releases; verify GitHub connectivity and, while the repository is private, set RELAYER_DEVELOPMENT=true with RELAYER_DEVELOPMENT_TOKEN"

    [[ "$RELAYER_PRERELEASE_FALLBACK" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*-[0-9A-Za-z.+-]+$ ]] || \
        die "no official production Relayer release is available and RELAYER_PRERELEASE_FALLBACK is not a valid prerelease tag"
    RELAYER_VERSION="$RELAYER_PRERELEASE_FALLBACK"
    printf 'No official production Relayer release is available; using reviewed prerelease fallback: %s\n' \
        "$RELAYER_VERSION" >&2
}

release_curl() {
    if [[ -n "$RELAYER_DEVELOPMENT_TOKEN" ]]; then
        curl --config <(printf 'header = "Authorization: Bearer %s"\n' "$RELAYER_DEVELOPMENT_TOKEN") "$@"
    else
        curl "$@"
    fi
}

k8s_doctor_command() {
    local command_name="$1" package_hint="$2" id
    id="$(printf '%s' "$command_name" | tr '[:lower:]-' '[:upper:]_')"
    if command -v "$command_name" >/dev/null 2>&1; then
        doctor_result PASS "K8S.TOOL.$id" "$command_name is available" none
    else
        doctor_result FAIL "K8S.TOOL.$id" "$command_name is missing" "run make k8s-relayer-prereqs or install $package_hint"
    fi
}

doctor_k8s() {
    # Mirrors doctor_vm: at install scope the checks a reapply is meant to repair
    # are WARN, so make k8s-relayer can run; at operations scope they are blockers.
    local doctor_scope="${1:-operations}"
    case "$doctor_scope" in
        operations|install) ;;
        *) die "internal error: unsupported Relayer doctor scope '$doctor_scope'" ;;
    esac
    DOCTOR_FAILURES=0
    DOCTOR_WARNINGS=0
    if [[ -n "${RELAYER_DOCTOR_FIXTURE:-}" ]]; then
        doctor_run_fixture "$RELAYER_DOCTOR_FIXTURE"
        return
    fi

    k8s_doctor_command kubectl kubectl
    k8s_doctor_command helm Helm
    k8s_doctor_command jq jq
    k8s_doctor_command curl curl

    if ! command -v kubectl >/dev/null 2>&1; then
        doctor_result SKIP K8S.CONTEXT.CURRENT "Kubernetes context was not checked" "run make k8s-relayer-prereqs and configure kubectl"
        doctor_result SKIP K8S.NAMESPACE.DISCOVERY "namespace was not discovered" "configure kubectl"
        doctor_finish
        return
    fi

    CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
    if [[ -n "$CONTEXT" ]]; then
        doctor_result PASS K8S.CONTEXT.CURRENT "current context is $CONTEXT" none
    else
        doctor_result FAIL K8S.CONTEXT.CURRENT "no current Kubernetes context is configured" "select the managed L1 cluster with kubectl config use-context <context>"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        doctor_result SKIP K8S.IDENTITY.CURRENT "Kubernetes identity was not parsed because jq is missing" "run make k8s-relayer-prereqs"
        doctor_result SKIP K8S.NAMESPACE.DISCOVERY "namespace was not discovered because jq is missing" "run make k8s-relayer-prereqs"
        doctor_result SKIP K8S.RBAC.EFFECTIVE "effective permissions were not checked" "install jq and rerun doctor"
        doctor_result SKIP K8S.L1_CONFIG.METADATA "managed L1 metadata was not checked" "install jq and rerun doctor"
        doctor_result SKIP K8S.WORKLOADS.DISCOVERY "RPC and validator resources were not checked" "install jq and rerun doctor"
        doctor_result SKIP K8S.RUNTIME.STATE "Relayer workload state was not checked" "install jq and rerun doctor"
        doctor_finish
        return
    fi

    local whoami current_namespace configmaps count
    whoami="$(kubectl auth whoami -o json 2>/dev/null || true)"
    OPERATOR_IDENTITY="$(jq -r '.status.userInfo.username // empty' <<<"$whoami" 2>/dev/null || true)"
    if [[ -n "$OPERATOR_IDENTITY" ]]; then
        doctor_result PASS K8S.IDENTITY.CURRENT "current Kubernetes identity is $OPERATOR_IDENTITY" none
    else
        doctor_result FAIL K8S.IDENTITY.CURRENT "current Kubernetes identity could not be resolved" "use kubectl with SelfSubjectReview support and valid cluster credentials"
    fi

    current_namespace="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
    current_namespace="${current_namespace:-default}"
    if kubectl -n "$current_namespace" get configmap l1-config >/dev/null 2>&1; then
        NAMESPACE="$current_namespace"
        doctor_result PASS K8S.NAMESPACE.DISCOVERY "l1-config was found in the current context namespace $NAMESPACE" none
    elif kubectl auth can-i list configmaps --all-namespaces 2>/dev/null | grep -qx yes; then
        configmaps="$(kubectl get configmaps --all-namespaces -o json 2>/dev/null || true)"
        count="$(jq '[.items[]? | select(.metadata.name == "l1-config")] | length' <<<"$configmaps" 2>/dev/null || echo 0)"
        if [[ "$count" -eq 1 ]]; then
            NAMESPACE="$(jq -r '.items[] | select(.metadata.name == "l1-config") | .metadata.namespace' <<<"$configmaps")"
            doctor_result PASS K8S.NAMESPACE.DISCOVERY "l1-config was uniquely discovered in namespace $NAMESPACE" "set the current context namespace to $NAMESPACE for the access-only identity"
        elif [[ "$count" -eq 0 ]]; then
            doctor_result FAIL K8S.NAMESPACE.DISCOVERY "no l1-config ConfigMap exists in the current context" "run make k8s-l1-configure in the managed L1 namespace"
        else
            doctor_result FAIL K8S.NAMESPACE.DISCOVERY "multiple l1-config ConfigMaps exist in the current context" "run kubectl config set-context --current --namespace=<intended-l1-namespace>"
        fi
    else
        doctor_result FAIL K8S.NAMESPACE.DISCOVERY "l1-config is absent from current namespace '$current_namespace' and cluster-wide discovery is not permitted" "run kubectl config set-context --current --namespace=<avalanche-l1-namespace>"
    fi

    if [[ -z "$NAMESPACE" ]]; then
        doctor_result SKIP K8S.RBAC.EFFECTIVE "effective namespace permissions were not checked" "repair namespace discovery"
        doctor_result SKIP K8S.L1_CONFIG.METADATA "managed L1 metadata was not checked" "repair namespace discovery"
        doctor_result SKIP K8S.WORKLOADS.DISCOVERY "RPC and validator resources were not checked" "repair namespace discovery"
        doctor_result SKIP K8S.RUNTIME.STATE "Relayer workload state was not checked" "repair namespace discovery"
        doctor_finish
        return
    fi

    local permission verb resource permission_id missing_permissions=0
    local -a permissions=(
        'get configmaps' 'list configmaps' 'create configmaps' 'patch configmaps' 'update configmaps' 'delete configmaps'
        'get secrets' 'list secrets' 'create secrets' 'patch secrets' 'update secrets' 'delete secrets'
        'get services' 'list services' 'get pods' 'list pods' 'create pods' 'delete pods'
        'create pods/portforward' 'create pods/exec' 'get pods/log'
        'get serviceaccounts' 'create serviceaccounts' 'patch serviceaccounts' 'update serviceaccounts' 'delete serviceaccounts'
        'get statefulsets.apps' 'list statefulsets.apps' 'create statefulsets.apps' 'patch statefulsets.apps' 'update statefulsets.apps' 'delete statefulsets.apps'
        'get persistentvolumeclaims' 'list persistentvolumeclaims' 'delete persistentvolumeclaims'
        'get roles.rbac.authorization.k8s.io' 'create roles.rbac.authorization.k8s.io' 'patch roles.rbac.authorization.k8s.io' 'update roles.rbac.authorization.k8s.io' 'delete roles.rbac.authorization.k8s.io'
        'get rolebindings.rbac.authorization.k8s.io' 'create rolebindings.rbac.authorization.k8s.io' 'patch rolebindings.rbac.authorization.k8s.io' 'update rolebindings.rbac.authorization.k8s.io' 'delete rolebindings.rbac.authorization.k8s.io'
        'get networkpolicies.networking.k8s.io' 'create networkpolicies.networking.k8s.io' 'patch networkpolicies.networking.k8s.io' 'update networkpolicies.networking.k8s.io' 'delete networkpolicies.networking.k8s.io'
        'get ingresses.networking.k8s.io' 'list ingresses.networking.k8s.io'
    )
    for permission in "${permissions[@]}"; do
        read -r verb resource <<<"$permission"
        permission_id="$(printf '%s_%s' "$verb" "$resource" | tr '[:lower:]' '[:upper:]')"
        permission_id="${permission_id//\//_}"
        permission_id="${permission_id//./_}"
        if kubectl auth can-i "$verb" "$resource" -n "$NAMESPACE" 2>/dev/null | grep -qx yes; then
            doctor_result PASS "K8S.RBAC.$permission_id" "$verb $resource is allowed in $NAMESPACE" none
        else
            missing_permissions=$((missing_permissions + 1))
            doctor_result FAIL "K8S.RBAC.$permission_id" "$verb $resource is denied in $NAMESPACE" "grant this verb/resource to the namespace-scoped deployment administrator"
        fi
    done
    if ((missing_permissions == 0)); then
        doctor_result PASS K8S.RBAC.EFFECTIVE "all installation and lifecycle capabilities are effective in $NAMESPACE" none
    else
        doctor_result FAIL K8S.RBAC.EFFECTIVE "$missing_permissions required namespace capabilities are denied" "apply each missing permission above; cluster-admin is sufficient but not required or recommended"
    fi

    local l1_config required_key missing_keys="" l1_env_path=""
    l1_config="$(kubectl -n "$NAMESPACE" get configmap l1-config -o json 2>/dev/null || true)"
    for required_key in NETWORK SUBNET_ID CHAIN_ID EVM_CHAIN_ID CHAIN_NAME POA_MANAGER VALIDATOR_MANAGER_PROXY; do
        jq -e --arg key "$required_key" '.data[$key] != null and .data[$key] != ""' >/dev/null <<<"$l1_config" || missing_keys="${missing_keys:+$missing_keys,}$required_key"
    done
    if [[ -z "$missing_keys" ]]; then
        doctor_result PASS K8S.L1_CONFIG.METADATA "l1-config contains the required managed-L1 metadata" none
    else
        doctor_result FAIL K8S.L1_CONFIG.METADATA "l1-config is missing: $missing_keys" "rerun make k8s-l1-configure and manager initialization"
    fi
    if [[ -f "$ROOT_DIR/l1.env" ]]; then
        l1_env_path="$ROOT_DIR/l1.env"
    elif [[ -f "$K8S_DIR/l1.env" ]]; then
        l1_env_path="$K8S_DIR/l1.env"
    fi
    if [[ -n "$l1_env_path" ]]; then
        local mismatch="" env_value_local config_value_local
        for required_key in NETWORK SUBNET_ID CHAIN_ID EVM_CHAIN_ID CHAIN_NAME POA_MANAGER VALIDATOR_MANAGER_PROXY; do
            env_value_local="$(awk -F= -v key="$required_key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$l1_env_path")"
            config_value_local="$(jq -r --arg key "$required_key" '.data[$key] // empty' <<<"$l1_config")"
            [[ -z "$env_value_local" || -z "$config_value_local" || "$env_value_local" == "$config_value_local" ]] || mismatch="${mismatch:+$mismatch,}$required_key"
        done
        if [[ -z "$mismatch" ]]; then
            doctor_result PASS K8S.L1_CONFIG.CONSISTENCY "l1.env and l1-config agree on managed-L1 metadata" none
        else
            doctor_result FAIL K8S.L1_CONFIG.CONSISTENCY "l1.env and l1-config differ for: $mismatch" "restore the matching workspace and rerun make k8s-l1-configure"
        fi
    else
        doctor_result FAIL K8S.L1_CONFIG.CONSISTENCY "generated l1.env is missing from the Avalanche Deploy workspace" "restore the generated l1.env for this managed L1"
    fi

    local services validators service_count validator_count
    services="$(kubectl -n "$NAMESPACE" get services -l app.kubernetes.io/name=l1-rpc -o json 2>/dev/null || true)"
    validators="$(kubectl -n "$NAMESPACE" get statefulsets -l app.kubernetes.io/name=l1-validator -o json 2>/dev/null || true)"
    service_count="$(jq '.items // [] | length' <<<"$services" 2>/dev/null || echo 0)"
    validator_count="$(jq '.items // [] | length' <<<"$validators" 2>/dev/null || echo 0)"
    if [[ "$service_count" -eq 1 && "$validator_count" -eq 1 ]]; then
        RPC_SERVICE="$(jq -r '.items[0].metadata.name' <<<"$services")"
        RPC_RELEASE="$(jq -r '.items[0].metadata.labels["app.kubernetes.io/instance"] // empty' <<<"$services")"
        VALIDATOR_RELEASE="$(jq -r '.items[0].metadata.labels["app.kubernetes.io/instance"] // empty' <<<"$validators")"
        doctor_result PASS K8S.WORKLOADS.DISCOVERY "one labeled RPC Service and validator StatefulSet were found" none
    else
        doctor_result FAIL K8S.WORKLOADS.DISCOVERY "expected one labeled RPC Service and validator StatefulSet; found $service_count and $validator_count" "repair standard Avalanche Deploy workload labels or rerun the L1 deployment"
    fi

    local pvc_count secret_exists=false sts_exists=false ready_replicas=0 replicas=0 statefulset_json='{}' relayer_pvcs='{}'
    kubectl -n "$NAMESPACE" get secret "$RELAYER_SECRET" >/dev/null 2>&1 && secret_exists=true
    relayer_pvcs="$(kubectl -n "$NAMESPACE" get pvc -l app.kubernetes.io/instance="$RELAYER_RELEASE" -o json 2>/dev/null || echo '{}')"
    pvc_count="$(jq '.items // [] | length' <<<"$relayer_pvcs" 2>/dev/null || echo 0)"
    if kubectl -n "$NAMESPACE" get statefulset relayer >/dev/null 2>&1; then
        sts_exists=true
        statefulset_json="$(kubectl -n "$NAMESPACE" get statefulset relayer -o json 2>/dev/null || echo '{}')"
        replicas="$(jq -r '.spec.replicas // 0' <<<"$statefulset_json")"
        ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$statefulset_json")"
    fi
    if [[ "$sts_exists" == true && "$secret_exists" == true && "$pvc_count" -eq 1 ]]; then
        doctor_result PASS K8S.RUNTIME.STATE "Relayer is installed with retained Secret and PVC" none
    elif [[ "$sts_exists" == false && "$secret_exists" == false && "$pvc_count" -eq 0 ]]; then
        doctor_result PASS K8S.RUNTIME.STATE "Relayer is not installed and is ready for a fresh install" none
    elif [[ "$sts_exists" == false && "$secret_exists" == true && "$pvc_count" -eq 1 ]]; then
        doctor_result PASS K8S.RUNTIME.STATE "Relayer workload is removed and retained Secret/PVC are ready for reinstall" none
    else
        doctor_result FAIL K8S.RUNTIME.STATE "Relayer workload, Secret, and PVC form a partial installation" "restore the matching retained resources or purge only after separately approving permanent deletion"
    fi

    if [[ "$sts_exists" == true && "$replicas" -eq 1 && "$ready_replicas" -eq 1 ]]; then
        doctor_result PASS K8S.RUNTIME.READY "Relayer StatefulSet has one ready replica" none
    elif [[ "$sts_exists" == true && "$doctor_scope" == install ]]; then
        doctor_result WARN K8S.RUNTIME.READY "Relayer StatefulSet readiness is $ready_replicas/$replicas" "this install/reapply will render configuration and restart the runtime"
    elif [[ "$sts_exists" == true ]]; then
        doctor_result FAIL K8S.RUNTIME.READY "Relayer StatefulSet readiness is $ready_replicas/$replicas" "inspect make k8s-relayer-logs and repair readiness before validator operations"
    else
        doctor_result SKIP K8S.RUNTIME.READY "runtime readiness does not apply while the workload is absent" "run make k8s-relayer to install or reapply"
    fi

    local storage_classes rpc_pvcs rpc_pvc_count
    if [[ "$pvc_count" -eq 1 ]]; then
        if jq -e '.items[0].spec.accessModes | index("ReadWriteOnce") != null' >/dev/null <<<"$relayer_pvcs"; then
            doctor_result PASS K8S.STORAGE.PVC "one retained ReadWriteOnce Relayer PVC exists" none
        else
            doctor_result FAIL K8S.STORAGE.PVC "the retained Relayer PVC does not support ReadWriteOnce" "restore a compatible retained PVC before reinstalling"
        fi
    elif [[ "$service_count" -eq 1 ]]; then
        rpc_pvcs="$(kubectl -n "$NAMESPACE" get pvc \
            -l "app.kubernetes.io/name=l1-rpc,app.kubernetes.io/instance=$RPC_RELEASE" -o json 2>/dev/null || echo '{}')"
        rpc_pvc_count="$(jq '[.items[]? | select((.status.phase == "Bound") and (.spec.accessModes | index("ReadWriteOnce") != null) and ((.spec.storageClassName // "") != ""))] | length' <<<"$rpc_pvcs" 2>/dev/null || echo 0)"
        if [[ "$rpc_pvc_count" -eq 1 ]]; then
            doctor_result PASS K8S.STORAGE.PVC "the managed RPC PVC proves a bound ReadWriteOnce StorageClass is available in $NAMESPACE" none
        elif kubectl auth can-i list storageclasses.storage.k8s.io 2>/dev/null | grep -qx yes; then
            storage_classes="$(kubectl get storageclass -o json 2>/dev/null | jq '
              [.items[]? | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")] as $defaults |
              if ($defaults | length) == 1 then 1 elif (.items // [] | length) == 1 then 1 else 0 end' || echo 0)"
            if [[ "$storage_classes" -eq 1 ]]; then
                doctor_result PASS K8S.STORAGE.PVC "one unambiguous StorageClass is available for a new Relayer PVC" none
            else
                doctor_result FAIL K8S.STORAGE.PVC "no single default or uniquely selectable StorageClass is available for the Relayer PVC" "ask the cluster operator to configure one default ReadWriteOnce-capable StorageClass"
            fi
        else
            doctor_result FAIL K8S.STORAGE.PVC "no bound managed RPC PVC proves namespace storage support, and StorageClass discovery is not permitted" "ask the cluster operator to confirm a ReadWriteOnce StorageClass, without granting Relayer cluster-wide privileges"
        fi
    else
        doctor_result FAIL K8S.STORAGE.PVC "PVC support cannot be inferred before the managed RPC Service is discovered" "repair the standard RPC labels, then rerun doctor"
    fi

    local images non_digest=0 image
    if [[ "$sts_exists" == true ]]; then
        images="$(jq -r '.spec.template.spec.initContainers[].image, .spec.template.spec.containers[].image' <<<"$statefulset_json")"
        while IFS= read -r image; do
            [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || non_digest=$((non_digest + 1))
        done <<<"$images"
        if ((non_digest == 0)); then
            doctor_result PASS K8S.IMAGES.IMMUTABLE "all Relayer pod images use immutable digests" none
        elif [[ "$doctor_scope" == install ]]; then
            # Same class as K8S.RELEASE.INTEGRITY, which the VM covers in one check:
            # the reapply is what repins these references, so blocking it here would
            # make the drifted install unrepairable by its own remediation.
            doctor_result WARN K8S.IMAGES.IMMUTABLE "$non_digest Relayer pod image reference(s) are mutable" "this install/reapply will restore the verified pinned digests"
        else
            doctor_result FAIL K8S.IMAGES.IMMUTABLE "$non_digest Relayer pod image reference(s) are mutable" "reapply the release using make k8s-relayer-upgrade RELAYER_VERSION=vX.Y.Z"
        fi
    else
        doctor_result SKIP K8S.IMAGES.IMMUTABLE "installed image references do not apply while the workload is absent" "the installer will use published digest assets"
    fi

    local public_services ingress_count public_endpoint_query=true service_json ingress_json
    service_json="$(kubectl -n "$NAMESPACE" get services -l app.kubernetes.io/instance="$RELAYER_RELEASE" -o json 2>/dev/null)" || public_endpoint_query=false
    ingress_json="$(kubectl -n "$NAMESPACE" get ingress -l app.kubernetes.io/instance="$RELAYER_RELEASE" -o json 2>/dev/null)" || public_endpoint_query=false
    # The {} default must stay quoted: bash otherwise ends the expansion at the first
    # brace and appends a stray } to the here-string, which makes jq fail on every
    # cluster and turns this check into a permanent false blocker.
    public_services="$(jq '[.items[]? | select(.spec.type == "NodePort" or .spec.type == "LoadBalancer") ] | length' <<<"${service_json:-"{}"}" 2>/dev/null || echo 0)"
    ingress_count="$(jq '.items // [] | length' <<<"${ingress_json:-"{}"}" 2>/dev/null || echo 0)"
    if [[ "$public_endpoint_query" != true ]]; then
        doctor_result FAIL K8S.ACCESS.PUBLIC_ENDPOINTS "public endpoint resources could not be inspected" "grant namespace-scoped list on Services and Ingresses, then rerun doctor"
    elif [[ "$public_services" -eq 0 && "$ingress_count" -eq 0 ]]; then
        doctor_result PASS K8S.ACCESS.PUBLIC_ENDPOINTS "no Relayer NodePort, LoadBalancer, or Ingress exists" none
    else
        doctor_result FAIL K8S.ACCESS.PUBLIC_ENDPOINTS "public Relayer endpoint resources were detected" "delete the Relayer Service/Ingress and use make k8s-relayer-access"
    fi
    if [[ "$sts_exists" == true ]] && kubectl -n "$NAMESPACE" get networkpolicy relayer >/dev/null 2>&1; then
        doctor_result PASS K8S.NETWORK_POLICY.PRESENT "Relayer default-deny NetworkPolicy is present" none
    elif [[ "$sts_exists" == true ]]; then
        doctor_result FAIL K8S.NETWORK_POLICY.PRESENT "Relayer NetworkPolicy is missing" "reapply the Relayer Helm release"
    else
        doctor_result SKIP K8S.NETWORK_POLICY.PRESENT "NetworkPolicy does not apply while the workload is absent" "the installer will create it"
    fi

    local binding role subjects subject_kind subject_name role_ref_name role_ref_kind exact_role
    binding="$(kubectl -n "$NAMESPACE" get rolebinding relayer-port-forward -o json 2>/dev/null || true)"
    role="$(kubectl -n "$NAMESPACE" get role relayer-port-forward -o json 2>/dev/null || true)"
    subjects="$(jq '.subjects // [] | length' <<<"$binding" 2>/dev/null || echo 0)"
    subject_kind="$(jq -r '.subjects[0].kind // empty' <<<"$binding" 2>/dev/null || true)"
    subject_name="$(jq -r '.subjects[0].name // empty' <<<"$binding" 2>/dev/null || true)"
    role_ref_name="$(jq -r '.roleRef.name // empty' <<<"$binding" 2>/dev/null || true)"
    role_ref_kind="$(jq -r '.roleRef.kind // empty' <<<"$binding" 2>/dev/null || true)"
    exact_role="$(jq -r --arg rpc "$RPC_SERVICE" '
      def norm: {apiGroups:((.apiGroups // [])|sort),resources:((.resources // [])|sort),verbs:((.verbs // [])|sort),resourceNames:((.resourceNames // [])|sort)};
      ([.rules[]? | norm] | sort_by(.resources|join(","))) ==
      ([
        {apiGroups:[""],resources:["pods"],verbs:["get","list"],resourceNames:[]},
        {apiGroups:[""],resources:["pods/portforward"],verbs:["create"],resourceNames:[]},
        {apiGroups:[""],resources:["services"],verbs:["get"],resourceNames:[$rpc]},
        {apiGroups:[""],resources:["configmaps"],verbs:["get"],resourceNames:["l1-config"]}
      ] | map(norm) | sort_by(.resources|join(",")))' <<<"$role" 2>/dev/null || echo false)"
    if [[ "$sts_exists" == false ]]; then
        doctor_result SKIP K8S.ACCESS.ROLE_BINDING "restricted access RoleBinding does not apply while the workload is absent" "the installer will bind one user"
    elif [[ "$subjects" -eq 1 && "$subject_kind" == User && "$subject_name" == "$OPERATOR_IDENTITY" && \
        "$role_ref_kind" == Role && "$role_ref_name" == relayer-port-forward && "$exact_role" == true ]]; then
        doctor_result PASS K8S.ACCESS.ROLE_BINDING "restricted access RoleBinding has exactly the current user and no secret/exec/log/mutation expansion" none
    else
        doctor_result FAIL K8S.ACCESS.ROLE_BINDING "restricted access Role/RoleBinding subject or permissions differ from the expected single-user contract" "reapply the chart as $OPERATOR_IDENTITY and remove any expanded Role rules"
    fi

    local base release_ok=true image_asset image_ref published_relayerd_image="" published_console_image=""
    base="https://github.com/$RELAYER_REPOSITORY/releases/download/$RELAYER_VERSION"
    release_curl -fsSL --retry 1 "$base/checksums.txt" >/dev/null 2>&1 || release_ok=false
    for image_asset in relayerd-image.txt relayer-console-image.txt; do
        image_ref="$(release_curl -fsSL --retry 1 "$base/$image_asset" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "$image_ref" =~ ^ghcr\.io/.+@sha256:[0-9a-f]{64}$ ]] || release_ok=false
        if [[ "$image_asset" == relayerd-image.txt ]]; then
            published_relayerd_image="$image_ref"
        else
            published_console_image="$image_ref"
        fi
    done
    if [[ "$release_ok" == true ]]; then
        doctor_result PASS K8S.RELEASE.AVAILABLE "$RELAYER_VERSION checksums and immutable image assets are anonymously available" none
    else
        doctor_result FAIL K8S.RELEASE.AVAILABLE "$RELAYER_VERSION release metadata is unavailable or mutable" "publish the tested public Relayer release or use an approved authenticated development override"
    fi

    if [[ "$sts_exists" == true ]]; then
        local actual_relayerd actual_console recorded_version recorded_relayerd recorded_console
        actual_relayerd="$(jq -r '.spec.template.spec.containers[] | select(.name == "relayerd") | .image' <<<"$statefulset_json")"
        actual_console="$(jq -r '.spec.template.spec.containers[] | select(.name == "console") | .image' <<<"$statefulset_json")"
        recorded_version="$(jq -r '.data.RELAYER_VERSION // empty' <<<"$l1_config")"
        recorded_relayerd="$(jq -r '.data.RELAYERD_IMAGE // empty' <<<"$l1_config")"
        recorded_console="$(jq -r '.data.RELAYER_CONSOLE_IMAGE // empty' <<<"$l1_config")"
        if [[ "$recorded_version" == "$RELAYER_VERSION" && "$actual_relayerd" == "$recorded_relayerd" && \
            "$actual_console" == "$recorded_console" && -n "$published_relayerd_image" && \
            "$recorded_relayerd" == "$published_relayerd_image" && "$recorded_console" == "$published_console_image" ]]; then
            doctor_result PASS K8S.RELEASE.INTEGRITY "StatefulSet images and l1-config match the selected published release" none
        elif [[ "$doctor_scope" == install ]]; then
            doctor_result WARN K8S.RELEASE.INTEGRITY "StatefulSet image digests, l1-config metadata, or selected version has drifted" "this install/reapply will restore the verified pinned artifacts"
        else
            doctor_result FAIL K8S.RELEASE.INTEGRITY "StatefulSet image digests, l1-config metadata, or selected version has drifted" "run make k8s-relayer-upgrade RELAYER_VERSION=$RELAYER_VERSION as the namespace administrator"
        fi
    else
        doctor_result SKIP K8S.RELEASE.INTEGRITY "installed release integrity does not apply while the workload is absent" "the installer will persist release metadata in l1-config"
    fi

    # The daemon reaches the Primary Network Info API through the managed in-cluster
    # RPC Service, never through the ephemeral operator port-forward the installer
    # uses for relayer-setup, so drift from that Service URL is a configuration bug.
    # Bootstrap drift is always repaired by reapplying the release, so at install
    # scope the remediation is this run itself, as in doctor_vm's VM.CONFIG.BOOTSTRAP.
    local recorded_rpc_service daemon_config_map installed_info_url managed_info_url=""
    local bootstrap_remediation="run make k8s-relayer to reapply the managed configuration"
    [[ "$doctor_scope" != install ]] || \
        bootstrap_remediation="this install/reapply will render the managed in-cluster Info API"
    if [[ -n "$RPC_SERVICE" ]]; then
        managed_info_url="http://$RPC_SERVICE:9650"
    else
        recorded_rpc_service="$(jq -r '.data.RELAYER_RPC_SERVICE // empty' <<<"$l1_config")"
        [[ -z "$recorded_rpc_service" ]] || managed_info_url="http://$recorded_rpc_service:9650"
    fi
    if [[ "$sts_exists" != true ]]; then
        doctor_result SKIP K8S.CONFIG.BOOTSTRAP "installed bootstrap configuration does not apply while the workload is absent" "the installer will render the managed in-cluster Info API"
    elif [[ -z "$managed_info_url" ]]; then
        doctor_result SKIP K8S.CONFIG.BOOTSTRAP "the managed Info API could not be selected without a discovered or recorded RPC Service" "repair the standard RPC labels, then rerun doctor"
    else
        daemon_config_map="$(jq -r '[.spec.template.spec.volumes[]? | select(.name == "config") | .configMap.name] | if length == 1 then .[0] else empty end' <<<"$statefulset_json")"
        installed_info_url="$(kubectl -n "$NAMESPACE" get configmap "${daemon_config_map:-relayer-config}" -o json 2>/dev/null | \
            jq -r '.data["config.json"] // empty | try fromjson catch {} | .["info-rpc-url"] // empty' 2>/dev/null || true)"
        if [[ -z "$installed_info_url" ]]; then
            doctor_result WARN K8S.CONFIG.BOOTSTRAP "the installed daemon config.json in ConfigMap ${daemon_config_map:-relayer-config} has no readable info-rpc-url" "$bootstrap_remediation"
        elif [[ "$installed_info_url" == "$managed_info_url" ]]; then
            doctor_result PASS K8S.CONFIG.BOOTSTRAP "installed info-rpc-url matches the managed in-cluster Info API $managed_info_url" none
        elif [[ "$installed_info_url" =~ ^https?://(127\.0\.0\.1|localhost|\[::1\])(:|/|$) ]]; then
            doctor_result WARN K8S.CONFIG.BOOTSTRAP "installed info-rpc-url $installed_info_url is a loopback endpoint that only exists while an operator port-forward is running, not the managed $managed_info_url" "$bootstrap_remediation"
        else
            doctor_result WARN K8S.CONFIG.BOOTSTRAP "installed info-rpc-url $installed_info_url differs from the managed $managed_info_url bootstrap source" "$bootstrap_remediation"
        fi
    fi

    local preflight_summary preflight_log preflight_reason preflight_forward_pid
    local owner_type="" poa_owner="" eligible_bootstrap=""
    local safe_summary safe_enabled="" safe_txs="" console_safe_keys
    if [[ "$service_count" -eq 1 && "$validator_count" -eq 1 && -n "$l1_env_path" ]] && \
        command -v helm >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        # The preflight runs in a subshell so the read-only doctor cannot inherit its
        # discovered globals; the marker line carries back only what the checks below
        # classify. Bootstrap eligibility is the Info API peer set intersected with the
        # current Primary Network validator set, as in the Ansible discovery playbook.
        # Both responses are hundreds of kilobytes on Fuji and larger on Mainnet, well
        # past the per-argument MAX_ARG_STRLEN, so they reach jq as files and never as
        # argv. The subshell also cannot export PF_PID or run the EXIT trap, so its
        # port-forward pid and its stderr are carried out through TMP_DIR.
        [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)"
        PF_PID_FILE="$TMP_DIR/doctor-port-forward.pid"
        preflight_log="$TMP_DIR/doctor-preflight.err"
        : >"$PF_PID_FILE"
        : >"$preflight_log"
        if preflight_summary="$( (
                L1_ENV="$l1_env_path"
                discover_workloads
                preflight
                rpc_call /ext/info info.peers '{}' >"$TMP_DIR/doctor-info-peers.json"
                rpc_call /ext/P platform.getCurrentValidators '{}' >"$TMP_DIR/doctor-primary-validators.json"
                printf 'K8S_DOCTOR|%s|%s|%s\n' "$OWNER_TYPE" "$POA_OWNER" "$(jq -n \
                    --slurpfile peers "$TMP_DIR/doctor-info-peers.json" \
                    --slurpfile validators "$TMP_DIR/doctor-primary-validators.json" \
                    '[$validators[0].result.validators // [] | .[].nodeID] as $primary |
                     [$peers[0].result.peers // [] | .[].nodeID | select(. as $id | $primary | index($id))] | length')"
            ) 2>"$preflight_log" | grep '^K8S_DOCTOR|' )"; then
            IFS='|' read -r _ owner_type poa_owner eligible_bootstrap <<<"$preflight_summary"
            doctor_result PASS K8S.RPC.HEALTH "RPC network, blockchain, EVM chain, and bootstrap state match managed metadata" none
            doctor_result PASS K8S.PEERS.VISIBLE "RPC sees every labeled validator peer" none
            doctor_result PASS K8S.MANAGER.TOPOLOGY "official PoAManager topology and EOA/Safe ownership are healthy" none
            if [[ "$eligible_bootstrap" =~ ^[0-9]+$ ]] && ((eligible_bootstrap > 0)); then
                doctor_result PASS K8S.PEERS.BOOTSTRAP "$managed_info_url exposes $eligible_bootstrap current Primary Network bootstrap peer(s)" none
            else
                doctor_result FAIL K8S.PEERS.BOOTSTRAP "$managed_info_url exposes no peers that are current Primary Network validators" "restore Primary Network peering on the managed RPC node so its Info API reports reachable Primary validator peers, then rerun doctor"
            fi

            if [[ "$owner_type" == Safe ]]; then
                safe_summary="$( (
                        OWNER_TYPE="$owner_type"
                        discover_safe
                        printf 'K8S_SAFE|%s|%s\n' "$SAFE_ENABLED" "$SAFE_TXS_SERVICE"
                    ) 2>/dev/null | grep '^K8S_SAFE|' || true)"
                IFS='|' read -r _ safe_enabled safe_txs <<<"$safe_summary"
            fi
            if [[ "$owner_type" == Safe && "$safe_enabled" == true ]]; then
                doctor_result PASS K8S.SAFE.DISCOVERY "PoAManager owner $poa_owner is a Safe served by the discovered safe-txs Service $safe_txs" none
            elif [[ "$owner_type" == Safe ]]; then
                doctor_result FAIL K8S.SAFE.DISCOVERY "PoAManager owner $poa_owner is a Safe, but no unique Avalanche Deploy Safe release with a safe-txs Service was discovered in $NAMESPACE" "install exactly one managed Safe release with safe-txs and safe-ui Services in $NAMESPACE, then rerun doctor"
            else
                doctor_result PASS K8S.SAFE.DISCOVERY "PoAManager owner $poa_owner is a supported EOA" none
            fi

            if [[ "$owner_type" != Safe ]]; then
                doctor_result SKIP K8S.SAFE.CONSOLE_ENV "Safe console variables do not apply to an EOA-owned PoAManager" none
            elif [[ "$sts_exists" != true ]]; then
                doctor_result SKIP K8S.SAFE.CONSOLE_ENV "Safe console variables do not apply while the Relayer workload is absent" "the installer will render SAFE_TX_SERVICE_URL, SAFE_UI_URL, and SAFE_ADDRESS"
            else
                console_safe_keys="$(jq -r '[.spec.template.spec.containers[] | select(.name == "console") | .env[]? |
                  select(.name == "SAFE_ADDRESS" or .name == "SAFE_TX_SERVICE_URL" or .name == "SAFE_UI_URL") |
                  select((.value // "") != "") | .name] | sort | join(",")' <<<"$statefulset_json" 2>/dev/null || true)"
                # As in doctor_vm's VM.SAFE.CONSOLE_ENV: a Safe-owned console that
                # lost SAFE_ADDRESS or its Transaction Service cannot propose any
                # validator change, so operations scope must block. Only an
                # install/reapply, which re-renders exactly these variables and
                # reconnects the discovered Safe release, downgrades it to a warning.
                if [[ "$console_safe_keys" != "SAFE_ADDRESS,SAFE_TX_SERVICE_URL,SAFE_UI_URL" && "$doctor_scope" == install ]]; then
                    doctor_result WARN K8S.SAFE.CONSOLE_ENV "installed Safe-owned console container is missing required Safe integration variables (present: ${console_safe_keys:-none})" "this install/reapply will render SAFE_TX_SERVICE_URL, SAFE_UI_URL, and SAFE_ADDRESS"
                elif [[ "$console_safe_keys" != "SAFE_ADDRESS,SAFE_TX_SERVICE_URL,SAFE_UI_URL" ]]; then
                    doctor_result FAIL K8S.SAFE.CONSOLE_ENV "installed Safe-owned console container is missing required Safe integration variables (present: ${console_safe_keys:-none})" "run make k8s-relayer to reapply the managed Safe integration"
                elif [[ "$ready_replicas" -ne 1 ]]; then
                    doctor_result WARN K8S.SAFE.CONSOLE_ENV "console Safe variables are complete, but the Transaction Service could not be probed from an unready console container" "repair runtime readiness, then rerun doctor"
                elif kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c console -- node -e \
                    'fetch(process.env.SAFE_TX_SERVICE_URL+"/api/v1/about/").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' >/dev/null 2>&1; then
                    doctor_result PASS K8S.SAFE.CONSOLE_ENV "console Safe variables are complete and the configured Transaction Service answers /api/v1/about/" none
                elif [[ "$doctor_scope" == install ]]; then
                    doctor_result WARN K8S.SAFE.CONSOLE_ENV "console Safe variables are complete, but the configured Transaction Service did not answer /api/v1/about/" "complete the install/reapply, then repair the Safe Transaction Service in $NAMESPACE"
                else
                    doctor_result FAIL K8S.SAFE.CONSOLE_ENV "console Safe variables are complete, but the configured Transaction Service did not answer /api/v1/about/" "repair the Safe Transaction Service in $NAMESPACE, then rerun doctor"
                fi
            fi
        else
            # The installer this FAIL blocks is the only other place the preflight
            # reason is printed, so carry the captured cause into the result itself.
            # The last two lines are the die() that stopped the preflight and, for a
            # nested command substitution, the one that caused it. Nothing on this
            # stderr is secret, and doctor_result sanitizes it before printing.
            preflight_reason="$(grep -v '^[[:space:]]*$' "$preflight_log" 2>/dev/null | tail -n 2 || true)"
            preflight_reason="${preflight_reason//$'\n'/; }"
            preflight_reason="${preflight_reason//Error: /}"
            doctor_result FAIL K8S.RPC.HEALTH "RPC, peer, or manager preflight failed${preflight_reason:+: $preflight_reason}" "repair the reported preflight cause on the managed L1, then rerun make k8s-relayer-doctor"
            doctor_result SKIP K8S.PEERS.VISIBLE "peer visibility was not independently confirmed" "repair the RPC preflight"
            doctor_result SKIP K8S.MANAGER.TOPOLOGY "manager topology was not independently confirmed" "repair the RPC preflight"
            doctor_result SKIP K8S.PEERS.BOOTSTRAP "Primary Network bootstrap eligibility was not independently confirmed" "repair the RPC preflight"
            doctor_result SKIP K8S.SAFE.DISCOVERY "EOA/Safe ownership was not independently confirmed" "repair the manager topology preflight"
            doctor_result SKIP K8S.SAFE.CONSOLE_ENV "installed Safe console variables were not checked" "repair the RPC preflight"
        fi
        # The subshell's port-forward outlives the command substitution that started
        # it, and only the pid file carries it back here, so close it as soon as the
        # preflight is done; cleanup() stays the backstop if the doctor aborts first.
        preflight_forward_pid="$(tr -dc '0-9' <"$PF_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$preflight_forward_pid" ]]; then
            kill "$preflight_forward_pid" >/dev/null 2>&1 || true
            : >"$PF_PID_FILE"
        fi
    else
        doctor_result SKIP K8S.RPC.HEALTH "RPC health was not checked because discovery metadata or operator tools are incomplete" "repair l1-config, l1.env, workload labels, and missing Helm/curl tools"
        doctor_result SKIP K8S.PEERS.VISIBLE "peer visibility was not checked" "repair discovery metadata"
        doctor_result SKIP K8S.MANAGER.TOPOLOGY "manager topology was not checked" "repair discovery metadata"
        doctor_result SKIP K8S.PEERS.BOOTSTRAP "Primary Network bootstrap eligibility was not checked" "repair discovery metadata"
        doctor_result SKIP K8S.SAFE.DISCOVERY "EOA/Safe ownership was not checked" "repair discovery metadata"
        doctor_result SKIP K8S.SAFE.CONSOLE_ENV "installed Safe console variables were not checked" "repair discovery metadata"
    fi

    if [[ "$sts_exists" == true && "$ready_replicas" -eq 1 ]]; then
        if kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c relayerd -- \
            /usr/local/bin/relayer-restore --check-keystore /data/keystore/keystore.json --password-env RELAYER_KEYSTORE_PASSWORD >/dev/null 2>&1; then
            doctor_result PASS K8S.KEYS.INTEGRITY "encrypted keystore decrypts inside the daemon container" none
        else
            doctor_result FAIL K8S.KEYS.INTEGRITY "encrypted keystore integrity check failed" "restore the matching Secret and PVC from retained recovery material"
        fi
        # The running daemon holds the live bbolt lock, so verify the rolling hot
        # backup it writes into /data/backups instead of /data/relayer.db.
        if kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c relayerd -- \
            /usr/local/bin/relayer-restore --check-db /data/backups/relayer.db.bak >/dev/null 2>&1; then
            doctor_result PASS K8S.STATE.INTEGRITY "the daemon-opened bbolt state has a structurally valid rolling hot backup" none
        elif kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c relayerd -- \
            sh -ec 'test -f /data/backups/relayer.db.bak' >/dev/null 2>&1; then
            doctor_result FAIL K8S.STATE.INTEGRITY "the rolling bbolt hot backup failed its read-only integrity check" "inspect make k8s-relayer-logs and create a validated make k8s-relayer-backup before lifecycle operations"
        elif kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c relayerd -- \
            sh -ec 'test -d /data/backups' >/dev/null 2>&1; then
            doctor_result WARN K8S.STATE.INTEGRITY "relayerd opened the live database but its first rolling hot backup is not available yet" "wait one five-minute backup interval, then rerun doctor"
        else
            doctor_result WARN K8S.STATE.INTEGRITY "the active daemon holds the live bbolt lock and its rolling hot backup could not be inspected" "repair runtime readiness, wait for a hot backup, then rerun doctor"
        fi
        local key_status
        key_status="$(kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c console -- node -e \
          'fetch("http://127.0.0.1:8081/keys").then(r=>r.json()).then(v=>process.stdout.write(JSON.stringify(v)))' 2>/dev/null || true)"
        if jq -e '.fundedFloat == true and .fundedGas == true' >/dev/null <<<"$key_status"; then
            doctor_result PASS K8S.FUNDING.READY "P-Chain float and L1 gas addresses meet daemon funding thresholds" none
        elif [[ "$doctor_scope" == install ]]; then
            doctor_result WARN K8S.FUNDING.READY "one or both public Relayer funding addresses are below threshold" "complete the install/reapply, then fund the addresses printed by make k8s-relayer-status"
        else
            doctor_result FAIL K8S.FUNDING.READY "one or both public Relayer funding addresses are below threshold" "fund RELAYER_PCHAIN_ADDRESS and RELAYER_EVM_ADDRESS from l1-config"
        fi
    else
        doctor_result SKIP K8S.KEYS.INTEGRITY "keystore integrity requires a ready workload" "install or repair the Relayer workload"
        if [[ "$sts_exists" == true ]]; then
            doctor_result WARN K8S.STATE.INTEGRITY "the installed daemon is not ready enough to verify its rolling bbolt hot backup" "repair runtime readiness, wait for a hot backup, then rerun doctor"
        else
            doctor_result SKIP K8S.STATE.INTEGRITY "state integrity requires a ready workload" "install or repair the Relayer workload"
        fi
        doctor_result SKIP K8S.FUNDING.READY "funding readiness requires a ready workload" "install or repair the Relayer workload"
    fi

    local last_backup backup_epoch now_epoch
    last_backup="$(jq -r '.data.RELAYER_LAST_BACKUP // empty' <<<"$l1_config")"
    if [[ -n "$last_backup" ]] && \
        backup_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_backup" +%s 2>/dev/null || date -d "$last_backup" +%s 2>/dev/null)" && \
        [[ "$backup_epoch" =~ ^[0-9]+$ ]]; then
        now_epoch="$(date +%s)"
        if (((now_epoch - backup_epoch) > 604800)); then
            doctor_result WARN K8S.BACKUPS.FRESHNESS "latest retained backup metadata is older than seven days: $last_backup" "run make k8s-relayer-backup"
        else
            doctor_result PASS K8S.BACKUPS.FRESHNESS "latest retained backup is $last_backup" none
        fi
    elif [[ "$sts_exists" == true ]]; then
        doctor_result WARN K8S.BACKUPS.FRESHNESS "no manual retained backup is recorded" "run make k8s-relayer-backup"
    else
        doctor_result SKIP K8S.BACKUPS.FRESHNESS "backup freshness does not apply before installation" "run a backup after installation"
    fi

    # Verify the newest retained archive against the sha256 its own manifest records.
    # Only the daemon container mounts the PVC, so the archive is hashed in place and
    # the manifest is validated here; a container without a shell degrades to WARN.
    local backup_verification backup_state backup_manifest backup_kind="" backup_archive="" backup_archive_sha=""
    if [[ "$sts_exists" != true ]]; then
        doctor_result SKIP K8S.BACKUPS.INTEGRITY "retained backup verification does not apply before installation" "run make k8s-relayer-backup after installation"
    elif [[ "$ready_replicas" -ne 1 ]]; then
        doctor_result WARN K8S.BACKUPS.INTEGRITY "the newest retained backup could not be verified while the Relayer pod is not ready" "repair runtime readiness, then rerun doctor"
    else
        backup_verification="$(kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c relayerd -- sh -ec \
            'cd /data/backups 2>/dev/null || { echo NODIR; exit 0; }; archive=$(ls -t manual-*.tar.gz 2>/dev/null | head -n 1); [ -n "$archive" ] || { echo NONE; exit 0; }; manifest=${archive%.tar.gz}.manifest.json; [ -f "$manifest" ] || { echo "NOMANIFEST $archive"; exit 0; }; echo "ARCHIVE $archive $(sha256sum "$archive" | cut -d" " -f1)"; cat "$manifest"' \
            2>/dev/null || true)"
        backup_state="$(head -n 1 <<<"$backup_verification")"
        backup_manifest="$(tail -n +2 <<<"$backup_verification")"
        read -r backup_kind backup_archive backup_archive_sha <<<"$backup_state"
        if [[ "$backup_kind" == NODIR ]]; then
            doctor_result WARN K8S.BACKUPS.INTEGRITY "the Relayer PVC has no /data/backups directory to verify" "run make k8s-relayer-backup before lifecycle changes"
        elif [[ "$backup_kind" == NONE ]]; then
            doctor_result WARN K8S.BACKUPS.INTEGRITY "no retained manual backup archive was found in the Relayer PVC" "run make k8s-relayer-backup before lifecycle changes"
        elif [[ "$backup_kind" == NOMANIFEST ]]; then
            doctor_result FAIL K8S.BACKUPS.INTEGRITY "retained backup $backup_archive has no manifest recording its checksum" "run make k8s-relayer-backup and retain the new archive/manifest pair"
        elif [[ "$backup_kind" != ARCHIVE ]]; then
            doctor_result WARN K8S.BACKUPS.INTEGRITY "the newest retained backup could not be verified inside the daemon container" "verify /data/backups on the Relayer PVC manually, or run make k8s-relayer-backup"
        elif ! jq -e --arg archive "$backup_archive" \
            '.schemaVersion == 1 and .kind == "avalanche-deploy-relayer-backup" and
             .archive.file == $archive and (.archive.sha256 | test("^[0-9a-f]{64}$"))' \
            >/dev/null <<<"$backup_manifest" 2>/dev/null; then
            doctor_result FAIL K8S.BACKUPS.INTEGRITY "the manifest retained beside $backup_archive is not a structurally valid Avalanche Deploy backup manifest" "run make k8s-relayer-backup and retain the new archive/manifest pair"
        elif [[ ! "$backup_archive_sha" =~ ^[0-9a-f]{64}$ ]]; then
            doctor_result WARN K8S.BACKUPS.INTEGRITY "the checksum of retained backup $backup_archive could not be computed inside the daemon container" "verify $backup_archive against its manifest manually, or run make k8s-relayer-backup"
        elif [[ "$backup_archive_sha" == "$(jq -r '.archive.sha256' <<<"$backup_manifest")" ]]; then
            doctor_result PASS K8S.BACKUPS.INTEGRITY "retained backup $backup_archive matches the sha256 recorded in its manifest" none
        else
            doctor_result FAIL K8S.BACKUPS.INTEGRITY "retained backup $backup_archive and its manifest checksum do not match" "run make k8s-relayer-backup and retain the new archive/manifest pair"
        fi
    fi

    doctor_finish
}

discover_namespace() {
    CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
    [[ -n "$CONTEXT" ]] || die "no current Kubernetes context; configure kubectl before running this command"

    local current_namespace configmaps count
    current_namespace="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
    current_namespace="${current_namespace:-default}"
    if kubectl -n "$current_namespace" get configmap l1-config >/dev/null 2>&1; then
        NAMESPACE="$current_namespace"
        return 0
    fi

    if ! kubectl auth can-i list configmaps --all-namespaces 2>/dev/null | grep -qx yes; then
        die "l1-config was not found in current namespace '$current_namespace' and this identity cannot discover it cluster-wide; run: kubectl config set-context --current --namespace=<avalanche-l1-namespace>"
    fi
    if ! configmaps="$(kubectl get configmaps --all-namespaces -o json 2>/dev/null)"; then
        die "cluster-wide ConfigMap discovery was authorized but failed; inspect the current context and API connectivity"
    fi
    count="$(jq '[.items[] | select(.metadata.name == "l1-config")] | length' <<<"$configmaps")"
    if [[ "$count" -eq 0 ]]; then
        die "no Avalanche Deploy l1-config ConfigMap found; run make k8s-l1-configure first"
    fi
    if [[ "$count" -ne 1 ]]; then
        die "found $count l1-config ConfigMaps in context '$CONTEXT'; set the current context namespace to the intended Avalanche Deploy L1"
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
    local services statefulsets service_count validator_count rpc_pvcs storage_classes
    services="$(kubectl -n "$NAMESPACE" get services \
        -l app.kubernetes.io/name=l1-rpc -o json)"
    service_count="$(jq '.items | length' <<<"$services")"
    [[ "$service_count" -eq 1 ]] || die "expected exactly one l1-rpc Service in namespace '$NAMESPACE', found $service_count"
    RPC_SERVICE="$(jq -r '.items[0].metadata.name' <<<"$services")"
    RPC_RELEASE="$(jq -r '.items[0].metadata.labels["app.kubernetes.io/instance"] // empty' <<<"$services")"
    [[ -n "$RPC_RELEASE" ]] || die "RPC Service '$RPC_SERVICE' lacks the standard app.kubernetes.io/instance label"
    rpc_pvcs="$(kubectl -n "$NAMESPACE" get pvc \
        -l "app.kubernetes.io/name=l1-rpc,app.kubernetes.io/instance=$RPC_RELEASE" -o json)"
    STORAGE_CLASS="$(jq -r '[.items[] | select((.status.phase == "Bound") and (.spec.accessModes | index("ReadWriteOnce") != null)) | .spec.storageClassName // empty] | unique | if length == 1 then .[0] else empty end' <<<"$rpc_pvcs")"
    if [[ -z "$STORAGE_CLASS" ]] && kubectl auth can-i list storageclasses.storage.k8s.io 2>/dev/null | grep -qx yes; then
        storage_classes="$(kubectl get storageclass -o json)"
        STORAGE_CLASS="$(jq -r '
          [.items[]? | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")] as $defaults |
          if ($defaults | length) == 1 then $defaults[0].metadata.name
          elif (.items // [] | length) == 1 then .items[0].metadata.name
          else empty end' <<<"$storage_classes")"
    fi
    [[ -n "$STORAGE_CLASS" ]] || die "could not infer one bound ReadWriteOnce StorageClass from the managed RPC PVC; ask the cluster operator to configure one default class"

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
    # A caller running this inside a command substitution never receives PF_PID, so
    # publish the pid where the parent shell can find and kill it.
    [[ -z "$PF_PID_FILE" ]] || printf '%s\n' "$PF_PID" >"$PF_PID_FILE"
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

# Best-effort detection of a protocol-private (validatorOnly) validator. The
# Kubernetes charts have no protocol-privacy support, so such a configuration can
# only have been applied out of band; this reads it exactly where AvalancheGo does,
# from --subnet-config-content on the container or <subnet-config-dir>/<subnetId>.json
# inside the pod. It only selects which truthful refusal the caller prints, so a
# missing pod spec, an absent config, or a denied exec is treated as "not detected".
validator_is_protocol_private() {
    local pod="$1" pod_json flags config_content subnet_dir pod_home config
    pod_json="$(kubectl -n "$NAMESPACE" get pod "$pod" -o json 2>/dev/null || true)"
    flags="$(jq -r '[(.spec.containers[]?.command // []), (.spec.containers[]?.args // [])] | flatten | .[]' \
        <<<"$pod_json" 2>/dev/null || true)"
    config_content="$(sed -n 's/^--subnet-config-content=//p' <<<"$flags" | tail -n 1)"
    if [[ -n "$config_content" ]]; then
        if base64 -d <<<"$config_content" 2>/dev/null | \
            jq -e --arg subnet "$SUBNET_ID" '.[$subnet].validatorOnly == true' >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    subnet_dir="$(sed -n 's/^--subnet-config-dir=//p' <<<"$flags" | tail -n 1)"
    if [[ -z "$subnet_dir" ]]; then
        pod_home="$(jq -r 'first(.spec.containers[]?.env[]? | select(.name == "HOME") | .value) // empty' \
            <<<"$pod_json" 2>/dev/null || true)"
        subnet_dir="${pod_home:-/root}/.avalanchego/configs/subnets"
    fi
    config="$(kubectl -n "$NAMESPACE" exec "$pod" -- cat "$subnet_dir/$SUBNET_ID.json" 2>/dev/null || true)"
    if jq -e '.validatorOnly == true' >/dev/null 2>&1 <<<"$config"; then
        return 0
    fi
    return 1
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
            # For a protocol-private validator this absence is the normal steady
            # state, and neither make k8s-l1-configure nor waiting can change it:
            # only adding a NodeID to allowedNodes can, which this path does not
            # implement. Refuse with the truthful reason instead of a peering error.
            if validator_is_protocol_private "$pod"; then
                die "validator pod '$pod' ($node_id) enforces protocol privacy (validatorOnly) for subnet '$SUBNET_ID', so RPC node '$RPC_SERVICE' can never see it until the NodeID is added to allowedNodes; the Kubernetes Relayer path does not support protocol-private L1s, so install and operate this Relayer with the Terraform/Ansible path (make relayer), which manages permanent-identity authorization"
            fi
            die "RPC node '$RPC_SERVICE' cannot see validator peer '$node_id'; confirm the validator finished bootstrapping and that nothing blocks P2P port 9651 between them. If this L1 is protocol-private (validatorOnly with allowedNodes), the Kubernetes Relayer path does not support it: use the Terraform/Ansible path (make relayer) instead"
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
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"$POA_OWNER")" != "0x0000000000000000000000000000000000000000" ]] || \
        die "PoAManager owner $POA_OWNER is the zero address; a renounced owner leaves no authority able to approve validator changes, so restore PoAManager ownership before installing"
    owner_code="$(evm_call eth_getCode "$(jq -cn --arg address "$POA_OWNER" '[$address,"latest"]')" | jq -r '.result // empty')"
    [[ -n "$owner_code" ]] || \
        die "the L1 RPC did not answer eth_getCode for PoAManager owner $POA_OWNER; an unanswered owner lookup cannot be classified as an EOA or a Safe, so repair the L1 RPC before installing"
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

download_release() {
    # Exactly what main() and resolve_release_version accept: a stricter pattern here
    # would die only after the recovery backup has already drained the workload.
    [[ "$RELAYER_VERSION" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || \
        die "RELAYER_VERSION must be a version tag beginning with v (found: $RELAYER_VERSION)"
    local need_setup="${1:-false}" os arch version asset base expected actual extracted image_asset image_ref
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
    [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)"
    release_curl -fL --retry 3 -o "$TMP_DIR/checksums.txt" "$base/checksums.txt" || die "failed to download Relayer release checksums"
    for image_asset in relayerd-image.txt relayer-console-image.txt; do
        release_curl -fL --retry 3 -o "$TMP_DIR/$image_asset" "$base/$image_asset" || die "failed to download $image_asset"
        expected="$(awk -v asset="$image_asset" '$2 == asset || $2 == "*" asset {print $1; exit}' "$TMP_DIR/checksums.txt")"
        [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "checksums.txt has no checksum for $image_asset"
        if command -v sha256sum >/dev/null 2>&1; then
            actual="$(sha256sum "$TMP_DIR/$image_asset" | awk '{print $1}')"
        else
            actual="$(shasum -a 256 "$TMP_DIR/$image_asset" | awk '{print $1}')"
        fi
        [[ "$(tr '[:upper:]' '[:lower:]' <<<"$actual")" == "$(tr '[:upper:]' '[:lower:]' <<<"$expected")" ]] || die "checksum mismatch for $image_asset"
        image_ref="$(tr -d '[:space:]' <"$TMP_DIR/$image_asset")"
        [[ "$image_ref" =~ ^ghcr\.io/.+@sha256:[0-9a-f]{64}$ ]] || die "$image_asset does not contain an immutable OCI digest"
        if [[ "$image_asset" == relayerd-image.txt ]]; then RELAYERD_IMAGE="$image_ref"; else CONSOLE_IMAGE="$image_ref"; fi
    done
    [[ "$need_setup" == "true" ]] || return 0

    release_curl -fL --retry 3 -o "$TMP_DIR/$asset" "$base/$asset" || die "failed to download Relayer release asset $asset"
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
        --arg relayerVersion "$RELAYER_VERSION" --arg relayerPod "$RELAYER_POD" \
        --arg relayerRelease "$RELAYER_RELEASE" --arg relayerOperator "$OPERATOR_IDENTITY" \
        --arg relayerRpcService "$RPC_SERVICE" --arg relayerdImage "$RELAYERD_IMAGE" \
        --arg relayerConsoleImage "$CONSOLE_IMAGE" \
        '{data:{SUBNET_ID:$subnet,CHAIN_ID:$chain,EVM_CHAIN_ID:$evm,CHAIN_NAME:$chainName,
          NETWORK:$network,POA_MANAGER:$poa,VALIDATOR_MANAGER_PROXY:$vm,
          VALIDATOR_PEERS:$peers,RPC_RELEASE:$rpcRelease,VALIDATOR_RELEASE:$validatorRelease,
          RELAYER_VERSION:$relayerVersion,RELAYER_POD:$relayerPod,RELAYER_RELEASE:$relayerRelease,
          RELAYER_OPERATOR_IDENTITY:$relayerOperator,RELAYER_RPC_SERVICE:$relayerRpcService,
          RELAYERD_IMAGE:$relayerdImage,RELAYER_CONSOLE_IMAGE:$relayerConsoleImage}}')"
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
    # Install scope, as installation.sh does with doctor_vm install: an unready,
    # drifted, or underfunded existing install is exactly what this reapply
    # repairs, so those checks must not refuse to let it run.
    if ! doctor_k8s install; then
        die "Relayer doctor found blockers; apply the printed remediations before installation"
    fi
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

    if helm status "$RELAYER_RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 && \
       kubectl -n "$NAMESPACE" get statefulset relayer >/dev/null 2>&1; then
        echo "Existing Relayer state was found; creating a recovery backup before reapplying."
        backup_relayer
    fi

    download_release true
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
        --arg relayerdImage "$RELAYERD_IMAGE" --arg consoleImage "$CONSOLE_IMAGE" \
        --arg storageClass "$STORAGE_CLASS" \
        '{fullnameOverride:"relayer",images:{relayerd:{reference:$relayerdImage},console:{reference:$consoleImage}},
          network:$network,l1:{subnetId:$subnet,blockchainId:$chain,evmChainId:$evm,
          chainName:$chainName,coinName:$coin,managerAddress:$manager,validatorManagerAddress:$vm},
          avalanchego:{serviceName:$rpc,httpPort:9650},runtimeSecret:{name:$secret},
          operatorIdentity:$operator,console:{origin:"http://127.0.0.1:3080",walletRpcTunnelPort:9652},manuallyTrackedPeers:$peers,
          persistence:{storageClass:$storageClass},
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
            node -e 'fetch("http://127.0.0.1:8081/keys").then(r=>r.json()).then(v=>process.stdout.write(JSON.stringify(v)))' 2>/dev/null || true)"
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
    require_commands jq kubectl
    discover_namespace
    RPC_SERVICE="$(config_value RELAYER_RPC_SERVICE)"
    RELAYER_POD="$(config_value RELAYER_POD)"
    CHAIN_ID="$(config_value CHAIN_ID)"
    [[ -n "$RPC_SERVICE" && -n "$RELAYER_POD" && -n "$CHAIN_ID" ]] || \
        die "l1-config lacks RELAYER_RPC_SERVICE, RELAYER_POD, or CHAIN_ID; rerun make k8s-relayer as the namespace administrator"
    kubectl -n "$NAMESPACE" get service "$RPC_SERVICE" >/dev/null || \
        die "recorded RPC Service '$RPC_SERVICE' is unavailable"
    kubectl -n "$NAMESPACE" get pod "$RELAYER_POD" >/dev/null || \
        die "recorded Relayer pod '$RELAYER_POD' is unavailable"
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
    kubectl -n "$NAMESPACE" get configmap l1-config -o json | jq -r '
      "Release: \(.data.RELAYER_VERSION // "unrecorded")\n" +
      "P-chain float: \(.data.RELAYER_PCHAIN_ADDRESS // "unavailable")\n" +
      "L1 EVM gas: \(.data.RELAYER_EVM_ADDRESS // "unavailable")"'
}

logs_relayer() {
    discover_installed
    kubectl -n "$NAMESPACE" logs -f "$RELAYER_POD" --all-containers=true --prefix=true
}

backup_relayer() {
    discover_installed
    local backup_pod="relayer-manual-backup" timestamp created_at replicas pod_manifest manifest manifest_b64 archive_name
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    archive_name="manual-$timestamp.tar.gz"
    replicas="$(kubectl -n "$NAMESPACE" get statefulset relayer -o jsonpath='{.spec.replicas}')"
    BACKUP_REPLICAS="$replicas"
    echo "Draining relayer before backup..."
    kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas=0 >/dev/null
    kubectl -n "$NAMESPACE" wait --for=delete "pod/$RELAYER_POD" --timeout="$TIMEOUT" >/dev/null || true
    kubectl -n "$NAMESPACE" delete pod "$backup_pod" --ignore-not-found --wait >/dev/null
    manifest="$(jq -cn \
      --arg version "$(config_value RELAYER_VERSION)" --arg network "$(config_value NETWORK)" \
      --arg subnet "$(config_value SUBNET_ID)" --arg blockchain "$(config_value CHAIN_ID)" \
      --arg evm "$(config_value EVM_CHAIN_ID)" --arg chainName "$(config_value CHAIN_NAME)" \
      --arg manager "$(config_value POA_MANAGER)" --arg vm "$(config_value VALIDATOR_MANAGER_PROXY)" \
      --arg pchain "$(config_value RELAYER_PCHAIN_ADDRESS)" --arg gas "$(config_value RELAYER_EVM_ADDRESS)" \
      --arg createdAt "$created_at" --arg archive "$archive_name" \
      '{schemaVersion:1,kind:"avalanche-deploy-relayer-backup",version:$version,network:$network,
        subnetId:$subnet,blockchainId:$blockchain,evmChainId:($evm|tonumber),chainName:$chainName,
        managerAddress:$manager,validatorManagerAddress:$vm,
        fundingAddresses:{pChain:$pchain,evm:$gas},createdAt:$createdAt,
        archive:{file:$archive,sha256:"__ARCHIVE_SHA256__"}}')"
    manifest_b64="$(printf '%s' "$manifest" | base64 | tr -d '\n')"
    pod_manifest="$(jq -cn --arg name "$backup_pod" --arg claim "data-relayer-0" \
      --arg archive "$archive_name" --arg manifest "${archive_name%.tar.gz}.manifest.json" \
      --arg manifestB64 "$manifest_b64" --arg image "$UTILITY_IMAGE" '
      {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-backup"}},
       spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
       containers:[{name:"backup",image:$image,command:["sh","-ec"],
       args:["cd /data; mkdir -p backups; entries=$(find . -mindepth 1 -maxdepth 1 ! -name backups ! -name .restore-stage -print); test -n \"$entries\"; tar -czf \"backups/"+$archive+"\" $entries; chmod 600 \"backups/"+$archive+"\"; archive_sha=$(sha256sum \"backups/"+$archive+"\" | cut -d\" \" -f1); printf %s \""+$manifestB64+"\" | base64 -d > \"backups/"+$manifest+".tmp\"; sed -e \"s/__ARCHIVE_SHA256__/$archive_sha/\" \"backups/"+$manifest+".tmp\" > \"backups/"+$manifest+"\"; rm \"backups/"+$manifest+".tmp\"; echo " + $archive],
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
    kubectl -n "$NAMESPACE" patch configmap l1-config --type merge \
      -p "$(jq -cn --arg timestamp "$created_at" --arg archive "$archive_name" \
        '{data:{RELAYER_LAST_BACKUP:$timestamp,RELAYER_LAST_BACKUP_FILE:$archive}}')" >/dev/null
    BACKUP_REPLICAS=""
}

clean_restore_stage() {
    local cleanup_pod="$1" claim="$2" pod_manifest
    pod_manifest="$(jq -cn --arg name "$cleanup_pod" --arg claim "$claim" --arg image "$UTILITY_IMAGE" '
      {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-restore"}},
       spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
       containers:[{name:"cleanup",image:$image,command:["sh","-ec"],args:["cd /data; rm -rf .restore-stage"],
       volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],
       volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
    if kubectl -n "$NAMESPACE" delete pod "$cleanup_pod" --ignore-not-found --wait >/dev/null 2>&1 && \
       printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null 2>&1 && \
       kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$cleanup_pod" --timeout="$TIMEOUT" >/dev/null 2>&1; then
        kubectl -n "$NAMESPACE" delete pod "$cleanup_pod" --wait >/dev/null 2>&1 || true
        # The stage is provably gone, so the EXIT trap must not repeat this.
        RESTORE_STAGE_CLAIM=""
        return 0
    fi
    # The stage is an extracted /data archive: the keystore is encrypted and its
    # password stays in the relayer-runtime Secret, so the exposed private material
    # is the node P2P TLS key, not the signing key.
    echo "Warning: staged restore material could not be removed; delete .restore-stage from PVC $claim, which holds the node P2P TLS private key tls/staker.key and the encrypted keystore/keystore.json." >&2
    return 0
}

restore_relayer() {
    require_commands base64 jq kubectl
    local backup="${BACKUP:-}" manifest_name confirmation claim="data-relayer-0"
    local restore_pod="relayer-restore-prepare" utility_pod="relayer-restore-db" apply_pod="relayer-restore-apply"
    local rollback_pod="relayer-restore-rollback" cleanup_pod="relayer-restore-cleanup"
    local timestamp pre_restore replicas="" pod_manifest manifest_json restore_failure=""
    [[ -n "$backup" ]] || die "BACKUP is required; use make k8s-relayer-restore BACKUP=manual-YYYYMMDDTHHMMSSZ.tar.gz"
    [[ "$backup" =~ ^manual-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]] || \
        die "BACKUP must be a retained filename only (manual-YYYYMMDDTHHMMSSZ.tar.gz); paths and traversal are rejected"
    manifest_name="${backup%.tar.gz}.manifest.json"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    pre_restore="pre-restore-$timestamp.tar.gz"

    discover_namespace
    kubectl -n "$NAMESPACE" get secret "$RELAYER_SECRET" >/dev/null 2>&1 || \
        die "retained Secret $RELAYER_SECRET is missing; restore the matching Secret before this backup"
    kubectl -n "$NAMESPACE" get pvc "$claim" >/dev/null 2>&1 || \
        die "retained PVC $claim is missing; the selected in-PVC backup is unavailable"
    RELAYER_POD="$(config_value RELAYER_POD)"
    RELAYER_POD="${RELAYER_POD:-relayer-0}"
    RELAYERD_IMAGE="$(config_value RELAYERD_IMAGE)"
    if [[ ! "$RELAYERD_IMAGE" =~ ^ghcr\.io/.+@sha256:[0-9a-f]{64}$ ]]; then
        download_release false
    fi

    printf 'Restore %s in %s/%s and retain an automatic pre-restore rollback? [y/N] ' \
        "$backup" "$CONTEXT" "$NAMESPACE"
    IFS= read -r confirmation
    case "$confirmation" in y|Y|yes|YES|Yes) ;; *) echo "Restore cancelled; no changes made."; return 0 ;; esac

    if kubectl -n "$NAMESPACE" get statefulset relayer >/dev/null 2>&1; then
        replicas="$(kubectl -n "$NAMESPACE" get statefulset relayer -o jsonpath='{.spec.replicas}')"
        BACKUP_REPLICAS="$replicas"
        kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas=0 >/dev/null
        kubectl -n "$NAMESPACE" wait --for=delete "pod/$RELAYER_POD" --timeout="$TIMEOUT" >/dev/null || true
    fi

    kubectl -n "$NAMESPACE" delete pod "$restore_pod" "$utility_pod" "$apply_pod" "$rollback_pod" "$cleanup_pod" \
        --ignore-not-found --wait >/dev/null
    pod_manifest="$(jq -cn --arg name "$restore_pod" --arg claim "$claim" --arg image "$UTILITY_IMAGE" \
      --arg archive "$backup" --arg manifest "$manifest_name" '
      {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-restore"}},
       spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
       containers:[{name:"prepare",image:$image,command:["sh","-ec"],
       args:["cd /data; test -f \"backups/"+$archive+"\"; test -f \"backups/"+$manifest+"\"; test $(grep -o \"\\\"sha256\\\":\\\"[0-9a-f]*\\\"\" \"backups/"+$manifest+"\" | wc -l) -eq 1; expected=$(grep -o \"\\\"sha256\\\":\\\"[0-9a-f]*\\\"\" \"backups/"+$manifest+"\" | cut -d\\\" -f4); actual=$(sha256sum \"backups/"+$archive+"\" | cut -d\" \" -f1); test \"$expected\" = \"$actual\"; tar -tvzf \"backups/"+$archive+"\" | awk \"substr(\\$1,1,1) !~ /[-d]/ {bad=1} END {exit bad}\"; tar -tzf \"backups/"+$archive+"\" | while IFS= read -r member; do case \"$member\" in /*|../*|*/../*|*/..) exit 1;; esac; done; cat \"backups/"+$manifest+"\""],
       volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],
       volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
    if ! printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null || \
       ! kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$restore_pod" --timeout="$TIMEOUT" >/dev/null; then
        kubectl -n "$NAMESPACE" logs "$restore_pod" 2>/dev/null || true
        die "selected backup failed checksum, credential, traversal, or presence validation"
    fi
    manifest_json="$(kubectl -n "$NAMESPACE" logs "$restore_pod")"
    kubectl -n "$NAMESPACE" delete pod "$restore_pod" --wait >/dev/null

    jq -e \
      --arg archive "$backup" --arg network "$(config_value NETWORK)" \
      --arg subnet "$(config_value SUBNET_ID)" --arg blockchain "$(config_value CHAIN_ID)" \
      --arg evm "$(config_value EVM_CHAIN_ID)" --arg chainName "$(config_value CHAIN_NAME)" \
      --arg manager "$(config_value POA_MANAGER)" --arg vm "$(config_value VALIDATOR_MANAGER_PROXY)" \
      '.schemaVersion == 1 and .kind == "avalanche-deploy-relayer-backup" and .archive.file == $archive and
       (.archive.sha256 | test("^[0-9a-f]{64}$")) and
       .network == $network and .subnetId == $subnet and .blockchainId == $blockchain and
       (.evmChainId|tostring) == $evm and .chainName == $chainName and
       (.managerAddress|ascii_downcase) == ($manager|ascii_downcase) and
       (.validatorManagerAddress|ascii_downcase) == ($vm|ascii_downcase)' \
      >/dev/null <<<"$manifest_json" || die "backup manifest belongs to a different Avalanche Deploy L1"

    pod_manifest="$(jq -cn --arg name "$restore_pod" --arg claim "$claim" --arg image "$UTILITY_IMAGE" \
      --arg archive "$backup" --arg pre "$pre_restore" '
      {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-restore"}},
       spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
       containers:[{name:"prepare",image:$image,command:["sh","-ec"],
       args:["cd /data; rm -rf .restore-stage; mkdir -p .restore-stage backups; chmod 700 .restore-stage; current=$(find . -mindepth 1 -maxdepth 1 ! -name backups ! -name .restore-stage -print); test -n \"$current\"; tar -czf \"backups/"+$pre+"\" $current; chmod 600 \"backups/"+$pre+"\"; tar -xzf \"backups/"+$archive+"\" -C .restore-stage; test -s .restore-stage/relayer.db; test -s .restore-stage/keystore/keystore.json; test -s .restore-stage/tls/staker.crt; test -s .restore-stage/tls/staker.key"],
       volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],
       volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
    # From here the PVC may hold .restore-stage, so the EXIT/INT/TERM trap owns its
    # removal on every path this function does not handle explicitly: an unguarded
    # kubectl failure, a pod deletion failure, or Ctrl-C during a pod wait.
    RESTORE_STAGE_POD="$cleanup_pod"
    RESTORE_STAGE_CLAIM="$claim"
    if ! printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null || \
       ! kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$restore_pod" --timeout="$TIMEOUT" >/dev/null; then
        clean_restore_stage "$cleanup_pod" "$claim"
        die "failed to stage the selected backup and pre-restore rollback"
    fi
    kubectl -n "$NAMESPACE" delete pod "$restore_pod" --wait >/dev/null

    pod_manifest="$(jq -cn --arg name "$utility_pod" --arg claim "$claim" --arg image "$RELAYERD_IMAGE" --arg secret "$RELAYER_SECRET" '
      {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-restore"}},
       spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532,seccompProfile:{type:"RuntimeDefault"}},
       initContainers:[{name:"keystore-check",image:$image,command:["/usr/local/bin/relayer-restore"],
       args:["--check-keystore","/data/.restore-stage/keystore/keystore.json","--password-env","RELAYER_KEYSTORE_PASSWORD"],
       env:[{name:"RELAYER_KEYSTORE_PASSWORD",valueFrom:{secretKeyRef:{name:$secret,key:"keystore-password"}}}],
       volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}],
       containers:[{name:"restore",image:$image,command:["/usr/local/bin/relayer-restore"],
       args:["--backup","/data/.restore-stage/relayer.db","--db","/data/relayer.db"],
       volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}],
       volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
    if ! printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null || \
       ! kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$utility_pod" --timeout="$TIMEOUT" >/dev/null; then
        kubectl -n "$NAMESPACE" logs "$utility_pod" 2>/dev/null || true
        # relayer-restore replaces /data/relayer.db in place, so a failure here can
        # leave a half-written database that the daemon must never open. Reapply the
        # pre-restore archive exactly as the identity-apply failure below does, and
        # keep the workload down if that rollback also fails.
        pod_manifest="$(jq -cn --arg name "$rollback_pod" --arg claim "$claim" --arg image "$UTILITY_IMAGE" --arg pre "$pre_restore" '
          {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-restore"}},
           spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
           containers:[{name:"rollback",image:$image,command:["sh","-ec"],args:["cd /data; find . -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} \\;; tar -xzf \"backups/"+$pre+"\" -C /data"],volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],
           volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
        if ! printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null || \
           ! kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$rollback_pod" --timeout="$TIMEOUT" >/dev/null; then
            BACKUP_REPLICAS=""
            clean_restore_stage "$cleanup_pod" "$claim"
            die "relayer-restore rejected the selected bbolt state and automatic rollback also failed; the workload remains scaled down and $pre_restore is retained for operator recovery"
        fi
        kubectl -n "$NAMESPACE" delete pod "$rollback_pod" --wait >/dev/null
        die "relayer-restore rejected the selected bbolt state; the pre-restore state was reapplied"
    fi
    kubectl -n "$NAMESPACE" delete pod "$utility_pod" --wait >/dev/null

    pod_manifest="$(jq -cn --arg name "$apply_pod" --arg claim "$claim" --arg image "$UTILITY_IMAGE" '
      {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-restore"}},
       spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
       containers:[{name:"apply",image:$image,command:["sh","-ec"],
       args:["cd /data; rm -rf keystore.restore tls.restore; cp -a .restore-stage/keystore keystore.restore; cp -a .restore-stage/tls tls.restore; rm -rf keystore tls; mv keystore.restore keystore; mv tls.restore tls; rm -rf .restore-stage"],
       volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],
       volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
    # The database has already been replaced here, so a failure to even create the
    # apply pod must enter the same rollback path as a failed wait; otherwise the
    # trap would restart the workload on new state with the old keys and TLS identity.
    if ! printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null || \
       ! kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$apply_pod" --timeout="$TIMEOUT" >/dev/null; then
        kubectl -n "$NAMESPACE" logs "$apply_pod" 2>/dev/null || true
        pod_manifest="$(jq -cn --arg name "$rollback_pod" --arg claim "$claim" --arg image "$UTILITY_IMAGE" --arg pre "$pre_restore" '
          {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-restore"}},
           spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
           containers:[{name:"rollback",image:$image,command:["sh","-ec"],args:["cd /data; find . -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} \\;; tar -xzf \"backups/"+$pre+"\" -C /data"],volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],
           volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
        if ! printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null || \
           ! kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$rollback_pod" --timeout="$TIMEOUT" >/dev/null; then
            BACKUP_REPLICAS=""
            clean_restore_stage "$cleanup_pod" "$claim"
            die "failed to apply matching encrypted keys/TLS identity and automatic rollback also failed; the workload remains scaled down and $pre_restore is retained for operator recovery"
        fi
        kubectl -n "$NAMESPACE" delete pod "$rollback_pod" --wait >/dev/null
        die "failed to apply matching encrypted keys/TLS identity; the pre-restore state was reapplied"
    fi
    kubectl -n "$NAMESPACE" delete pod "$apply_pod" --wait >/dev/null
    # The apply pod removed .restore-stage as its last step, so the trap has nothing
    # left to clean.
    RESTORE_STAGE_CLAIM=""

    if [[ -n "$replicas" ]]; then
        kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas="$replicas" >/dev/null
        BACKUP_REPLICAS=""
        # Only conditions that mean this restore itself failed may discard it: the
        # workload not becoming ready on the restored state, the restored keystore
        # not decrypting with the retained Secret credential, and a restored bbolt
        # state whose rolling hot backup fails its read-only check. The full
        # operations doctor is deliberately not the gate: a briefly down Safe
        # Transaction Service, zero current Primary-validator peers, an underfunded
        # wallet, or release drift are all external to the restore, and reverting a
        # verified restore because of them destroys good state.
        if ! kubectl -n "$NAMESPACE" rollout status statefulset/relayer --timeout="$TIMEOUT"; then
            restore_failure="the restored workload did not become ready"
        elif ! kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c relayerd -- \
            /usr/local/bin/relayer-restore --check-keystore /data/keystore/keystore.json \
            --password-env RELAYER_KEYSTORE_PASSWORD >/dev/null 2>&1; then
            restore_failure="the restored encrypted keystore does not decrypt with the retained Secret credential"
        elif kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c relayerd -- \
            sh -ec 'test -f /data/backups/relayer.db.bak' >/dev/null 2>&1 && \
            ! kubectl -n "$NAMESPACE" exec "$RELAYER_POD" -c relayerd -- \
            /usr/local/bin/relayer-restore --check-db /data/backups/relayer.db.bak >/dev/null 2>&1; then
            restore_failure="the restored bbolt state failed the read-only integrity check of its rolling hot backup"
        fi
        if [[ -n "$restore_failure" ]]; then
            echo "Restore readiness failed ($restore_failure); automatically reapplying $pre_restore..." >&2
            kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas=0 >/dev/null
            kubectl -n "$NAMESPACE" wait --for=delete "pod/$RELAYER_POD" --timeout="$TIMEOUT" >/dev/null || true
            pod_manifest="$(jq -cn --arg name "$rollback_pod" --arg claim "$claim" --arg image "$UTILITY_IMAGE" --arg pre "$pre_restore" '
              {apiVersion:"v1",kind:"Pod",metadata:{name:$name,labels:{"app.kubernetes.io/name":"relayer-restore"}},
               spec:{restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:65532,runAsGroup:65532,fsGroup:65532},
               containers:[{name:"rollback",image:$image,command:["sh","-ec"],args:["cd /data; find . -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} \\;; tar -xzf \"backups/"+$pre+"\" -C /data"],volumeMounts:[{name:"data",mountPath:"/data"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],
               volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}')"
            printf '%s\n' "$pod_manifest" | kubectl -n "$NAMESPACE" apply -f - >/dev/null || \
                die "automatic restore rollback could not be started; retained $pre_restore requires operator recovery"
            kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$rollback_pod" --timeout="$TIMEOUT" >/dev/null || \
                die "automatic restore rollback failed; retained $pre_restore requires operator recovery"
            kubectl -n "$NAMESPACE" delete pod "$rollback_pod" --wait >/dev/null
            kubectl -n "$NAMESPACE" scale statefulset/relayer --replicas="$replicas" >/dev/null
            kubectl -n "$NAMESPACE" rollout status statefulset/relayer --timeout="$TIMEOUT" || true
            die "restore failed readiness and the pre-restore state was reapplied"
        fi
    else
        echo "Backup restored into retained PVC $claim. The workload remains removed; run make k8s-relayer to reinstall it."
    fi
    echo "Restore completed. Automatic rollback material is retained as $pre_restore inside the Relayer PVC."
    # As in the VM restore, the full operations sweep runs after the restore is
    # verified and reports on the whole deployment. Its blockers change only this
    # command's exit status; the restored state is kept either way.
    doctor_k8s operations || \
        die "the restore completed and passed its state, key, and readiness checks, but the operations doctor above reports blockers unrelated to it; repair them with make k8s-relayer-doctor"
}

upgrade_relayer() {
    discover_installed
    [[ "$RELAYER_VERSION" != "$DEFAULT_RELAYER_VERSION_SELECTOR" ]] || \
        die "RELAYER_VERSION is required for upgrades; run make k8s-relayer-upgrade RELAYER_VERSION=vX.Y.Z"
    [[ "$RELAYER_VERSION" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || die "invalid RELAYER_VERSION: $RELAYER_VERSION"
    local revision previous_version previous_relayerd previous_console metadata_patch
    revision="$(helm history "$RELAYER_RELEASE" -n "$NAMESPACE" -o json | jq -r 'map(select(.status == "deployed")) | last | .revision')"
    previous_version="$(config_value RELAYER_VERSION)"
    previous_relayerd="$(config_value RELAYERD_IMAGE)"
    previous_console="$(config_value RELAYER_CONSOLE_IMAGE)"
    backup_relayer
    download_release false
    echo "Upgrading Relayer to $RELAYER_VERSION..."
    if ! helm upgrade "$RELAYER_RELEASE" "$K8S_DIR/helm/relayerd" -n "$NAMESPACE" \
        --reuse-values --set-string "images.relayerd.reference=$RELAYERD_IMAGE" \
        --set-string "images.console.reference=$CONSOLE_IMAGE" --wait --timeout "$TIMEOUT"; then
        echo "Upgrade failed; rolling back to Helm revision $revision..." >&2
        helm rollback "$RELAYER_RELEASE" "$revision" -n "$NAMESPACE" --wait --timeout "$TIMEOUT" || \
            die "upgrade and automatic Helm rollback both failed; use helm history and the retained backup"
        die "upgrade failed and the prior revision was restored"
    fi
    metadata_patch="$(jq -cn --arg version "$RELAYER_VERSION" --arg daemon "$RELAYERD_IMAGE" --arg console "$CONSOLE_IMAGE" \
      '{data:{RELAYER_VERSION:$version,RELAYERD_IMAGE:$daemon,RELAYER_CONSOLE_IMAGE:$console}}')"
    if ! kubectl -n "$NAMESPACE" patch configmap l1-config --type merge -p "$metadata_patch" >/dev/null || \
       ! kubectl -n "$NAMESPACE" rollout status statefulset/relayer --timeout="$TIMEOUT"; then
        echo "Upgrade post-apply verification failed; rolling back to Helm revision $revision..." >&2
        helm rollback "$RELAYER_RELEASE" "$revision" -n "$NAMESPACE" --wait --timeout "$TIMEOUT" || \
            die "upgrade verification and automatic Helm rollback both failed; use helm history and the retained backup"
        kubectl -n "$NAMESPACE" patch configmap l1-config --type merge \
            -p "$(jq -cn --arg version "$previous_version" --arg daemon "$previous_relayerd" --arg console "$previous_console" \
              '{data:{RELAYER_VERSION:$version,RELAYERD_IMAGE:$daemon,RELAYER_CONSOLE_IMAGE:$console}}')" >/dev/null || true
        die "upgrade verification failed and the prior revision was restored"
    fi
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
        -p='{"data":{"RELAYER_PCHAIN_ADDRESS":null,"RELAYER_EVM_ADDRESS":null,"RELAYER_VERSION":null,"RELAYER_POD":null,"RELAYER_RELEASE":null,"RELAYER_OPERATOR_IDENTITY":null,"RELAYER_RPC_SERVICE":null,"RELAYERD_IMAGE":null,"RELAYER_CONSOLE_IMAGE":null,"RELAYER_LAST_BACKUP":null,"RELAYER_LAST_BACKUP_FILE":null}}' >/dev/null
    echo "Relayer keys, state, TLS identity, and backups permanently deleted."
}

main() {
[[ $# -le 1 ]] || { usage >&2; exit 2; }
validate_release_source
# upgrade is excluded: it must see the unresolved selector to refuse an
# implicit version, and it validates the operator-supplied tag itself.
if [[ "$ACTION" =~ ^(doctor|install|restore)$ ]]; then
    resolve_release_version
    if [[ ! "$RELAYER_VERSION" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
        echo "Error: RELAYER_VERSION must be official-latest or a release tag such as v0.1.0" >&2
        usage >&2
        exit 2
    fi
fi
case "$ACTION" in
    prereqs) exec "$ROOT_DIR/scripts/shared/relayer-prereqs.sh" k8s ;;
    doctor) doctor_k8s ;;
    install) install_relayer ;;
    access) access_relayer ;;
    status) status_relayer ;;
    logs) logs_relayer ;;
    backup) backup_relayer ;;
    restore) restore_relayer ;;
    upgrade) upgrade_relayer ;;
    remove) remove_relayer ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
