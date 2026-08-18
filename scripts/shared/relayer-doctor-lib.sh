#!/usr/bin/env bash
# Shared, side-effect-free result formatting for managed Relayer diagnostics.

DOCTOR_FAILURES=0
DOCTOR_WARNINGS=0

doctor_sanitize() {
    local value="$*"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//|//}"
    printf '%s' "$value"
}

doctor_result() {
    local level="$1" id="$2" summary="$3" remediation="${4:-none}"
    case "$level" in
        PASS|SKIP) ;;
        WARN) DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1)) ;;
        FAIL) DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1)) ;;
        *)
            printf 'FAIL DOCTOR.INTERNAL.LEVEL | invalid diagnostic level | remediation: report this bug with the command output\n' >&2
            DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
            return 2
            ;;
    esac
    printf '%s %s | %s | remediation: %s\n' \
        "$level" "$id" "$(doctor_sanitize "$summary")" "$(doctor_sanitize "$remediation")"
}

doctor_finish() {
    if ((DOCTOR_FAILURES > 0)); then
        printf 'Relayer doctor found %d blocker(s) and %d warning(s).\n' "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS"
        return 1
    fi
    printf 'Relayer doctor found no blockers and %d warning(s).\n' "$DOCTOR_WARNINGS"
    return 0
}

# Test-only fixture input is a pipe-delimited file containing
# LEVEL|ID|SUMMARY|REMEDIATION. It exercises stable result/exit semantics without
# contacting real infrastructure.
doctor_run_fixture() {
    local fixture="$1" level id summary remediation
    [[ -f "$fixture" ]] || {
        doctor_result FAIL DOCTOR.FIXTURE.MISSING "fixture file is missing" "create $fixture"
        doctor_finish
        return
    }
    while IFS='|' read -r level id summary remediation; do
        [[ -n "$level" ]] || continue
        doctor_result "$level" "$id" "$summary" "$remediation"
    done <"$fixture"
    doctor_finish
}
