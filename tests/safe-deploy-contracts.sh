#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# The single-quoted lines are the literal contents of the fake cast executable.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == "code" ]]; then' \
  '  printf "0x6000\n"' \
  '  exit 0' \
  'fi' \
  'echo "unexpected mutating cast command: $*" >&2' \
  'exit 99' \
  > "${TMP_DIR}/cast"
chmod 0755 "${TMP_DIR}/cast"

output="$(
  PATH="${TMP_DIR}:${PATH}" \
  RPC_URL="http://rpc.invalid" \
  PRIVATE_KEY="0x01" \
  "${REPO_ROOT}/scripts/l1/safe/deploy-contracts.sh"
)"

grep -q "SafeL2 already deployed" <<< "${output}"
grep -q "SimulateTxAccessor already deployed" <<< "${output}"
grep -q "Summary: 0 deployed, 8 already existed, 0 failed" <<< "${output}"

echo "Safe contract deployment script compatibility test passed"
