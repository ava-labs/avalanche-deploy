#!/usr/bin/env bash
# Render every restore helper Pod and exercise the normally-removed recovery path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=kubernetes/scripts/relayer.sh
source "$ROOT_DIR/kubernetes/scripts/relayer.sh"

require_commands() { :; }
# The sourced lifecycle functions consume these globals after discovery.
# shellcheck disable=SC2034
discover_namespace() { NAMESPACE=test-l1; CONTEXT=fixture; }
doctor_k8s() { [[ "${FIXTURE_DOCTOR_FAIL:-false}" != true ]]; }
config_value() {
    case "$1" in
        NETWORK) printf fuji ;;
        SUBNET_ID) printf subnet-test ;;
        CHAIN_ID) printf blockchain-test ;;
        EVM_CHAIN_ID) printf 99999 ;;
        CHAIN_NAME) printf test-chain ;;
        POA_MANAGER) printf 0x1111111111111111111111111111111111111111 ;;
        VALIDATOR_MANAGER_PROXY) printf 0x2222222222222222222222222222222222222222 ;;
        RELAYER_POD) printf relayer-0 ;;
        RELAYERD_IMAGE) printf 'ghcr.io/ava-labs/relayerd@sha256:%064d' 0 ;;
    esac
}
kubectl() {
    if [[ "$*" == *"get statefulset relayer"* ]]; then
        if [[ "${FIXTURE_INSTALLED:-false}" == true ]]; then
            [[ "$*" == *"jsonpath"* ]] && printf 1
            return 0
        fi
        return 1
    fi
    if [[ "$*" == *"apply -f -"* ]]; then
        local manifest name
        manifest="$(jq -e .)"
        name="$(jq -r '.metadata.name' <<<"$manifest")"
        [[ -z "${APPLIED_PODS_FILE:-}" ]] || printf '%s\n' "$name" >>"$APPLIED_PODS_FILE"
        return
    fi
    if [[ "$*" == *"wait"*"pod/relayer-restore-prepare"* && "${FIXTURE_PREPARE_FAIL:-false}" == true ]]; then
        return 1
    fi
    if [[ "$*" == *"wait"*"pod/relayer-restore-apply"* && "${FIXTURE_APPLY_FAIL:-false}" == true ]]; then
        return 1
    fi
    if [[ "$*" == *"wait"*"pod/relayer-restore-rollback"* && "${FIXTURE_ROLLBACK_FAIL:-false}" == true ]]; then
        return 1
    fi
    # The post-restore gate consults only conditions that mean this restore failed:
    # workload readiness, the restored keystore, and the restored hot backup.
    if [[ "$*" == *"rollout status statefulset/relayer"* && "${FIXTURE_READINESS_FAIL:-false}" == true ]]; then
        return 1
    fi
    if [[ "$*" == *"--check-keystore"* && "${FIXTURE_KEYSTORE_FAIL:-false}" == true ]]; then
        return 1
    fi
    if [[ "$*" == *"logs relayer-restore-prepare"* ]]; then
        jq -cn --arg network "${FIXTURE_NETWORK:-fuji}" '{
          schemaVersion:1, kind:"avalanche-deploy-relayer-backup",
          archive:{file:"manual-20260716T120000Z.tar.gz",sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, network:$network,
          subnetId:"subnet-test", blockchainId:"blockchain-test", evmChainId:99999,
          chainName:"test-chain", managerAddress:"0x1111111111111111111111111111111111111111",
          validatorManagerAddress:"0x2222222222222222222222222222222222222222"
        }'
        return
    fi
    return 0
}

output="$(BACKUP=manual-20260716T120000Z.tar.gz restore_relayer <<<y)"
grep -Fq 'The workload remains removed' <<<"$output"
grep -Fq 'Restore completed' <<<"$output"

set +e
output="$(BACKUP=../manual-20260716T120000Z.tar.gz restore_relayer 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] && grep -Fq 'paths and traversal are rejected' <<<"$output"

set +e
output="$(FIXTURE_NETWORK=mainnet BACKUP=manual-20260716T120000Z.tar.gz restore_relayer <<<y 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] && grep -Fq 'different Avalanche Deploy L1' <<<"$output"

set +e
output="$(FIXTURE_PREPARE_FAIL=true BACKUP=manual-20260716T120000Z.tar.gz restore_relayer <<<y 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] && grep -Fq 'failed checksum, credential, traversal, or presence validation' <<<"$output"

# A blocker from the operations doctor is NOT a failed restore. The restore must keep
# its result and report the unrelated blockers, never discard good restored state.
APPLIED_PODS_FILE="$(mktemp "${TMPDIR:-/tmp}/relayer-restore-pods.XXXXXX")"
set +e
output="$(FIXTURE_INSTALLED=true FIXTURE_DOCTOR_FAIL=true APPLIED_PODS_FILE="$APPLIED_PODS_FILE" \
    BACKUP=manual-20260716T120000Z.tar.gz restore_relayer <<<y 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || { echo "unrelated doctor blockers did not set a failing status" >&2; exit 1; }
grep -Fq 'Restore completed' <<<"$output"
grep -Fq 'blockers unrelated to it' <<<"$output"
grep -Fq 'automatically reapplying' <<<"$output" && \
    { echo "an unrelated doctor blocker rolled back a good restore" >&2; exit 1; }
grep -Fq 'relayer-restore-rollback' "$APPLIED_PODS_FILE" && \
    { echo "an unrelated doctor blocker applied a rollback pod" >&2; exit 1; }
rm -f "$APPLIED_PODS_FILE"

# The gate's own conditions must still roll back: workload readiness on the restored
# state, and the restored keystore failing to decrypt with the retained credential.
for fixture in FIXTURE_READINESS_FAIL FIXTURE_KEYSTORE_FAIL; do
    APPLIED_PODS_FILE="$(mktemp "${TMPDIR:-/tmp}/relayer-restore-pods.XXXXXX")"
    set +e
    output="$(FIXTURE_INSTALLED=true APPLIED_PODS_FILE="$APPLIED_PODS_FILE" \
        BACKUP=manual-20260716T120000Z.tar.gz \
        eval "$fixture=true; restore_relayer" <<<y 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || { echo "$fixture did not fail the restore" >&2; exit 1; }
    grep -Fq 'automatically reapplying' <<<"$output" || \
        { echo "$fixture did not reapply the pre-restore archive" >&2; exit 1; }
    grep -Fq 'relayer-restore-rollback' "$APPLIED_PODS_FILE" || \
        { echo "$fixture did not apply a rollback pod" >&2; exit 1; }
    rm -f "$APPLIED_PODS_FILE"
done

APPLIED_PODS_FILE="$(mktemp "${TMPDIR:-/tmp}/relayer-restore-pods.XXXXXX")"
set +e
output="$(FIXTURE_APPLY_FAIL=true APPLIED_PODS_FILE="$APPLIED_PODS_FILE" \
    BACKUP=manual-20260716T120000Z.tar.gz restore_relayer <<<y 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || { echo "identity-apply failure did not fail" >&2; exit 1; }
grep -Fq 'pre-restore state was reapplied' <<<"$output"
grep -Fq 'relayer-restore-rollback' "$APPLIED_PODS_FILE"
rm -f "$APPLIED_PODS_FILE"

set +e
output="$(FIXTURE_INSTALLED=true FIXTURE_APPLY_FAIL=true FIXTURE_ROLLBACK_FAIL=true \
    BACKUP=manual-20260716T120000Z.tar.gz restore_relayer <<<y 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || { echo "rollback failure did not fail" >&2; exit 1; }
grep -Fq 'workload remains scaled down' <<<"$output"

echo "Kubernetes Relayer restore smoke test passed"
