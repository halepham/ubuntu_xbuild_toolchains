#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Minimal, dependency-free test harness (no bats/shunit2 so the CI job only
# needs a stock bash + coreutils). Sourced by tests/*.sh.
# -----------------------------------------------------------------------------

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _C_RED='\033[0;31m'; _C_GRN='\033[0;32m'; _C_NC='\033[0m'
else
    _C_RED=''; _C_GRN=''; _C_NC=''
fi

_pass() { printf "${_C_GRN}  ok${_C_NC}   %s\n" "$1"; }
_fail() {
    printf "${_C_RED}  FAIL${_C_NC} %s\n" "$1"
    [ -n "${2:-}" ] && printf "       %s\n" "$2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# it "name" — start a test case (records the name for nicer output).
it() { CURRENT_TEST="$1"; TESTS_RUN=$((TESTS_RUN + 1)); }

# assert_contains HAYSTACK NEEDLE [msg]
assert_contains() {
    case "$1" in
        *"$2"*) _pass "$CURRENT_TEST" ;;
        *) _fail "$CURRENT_TEST" "expected output to contain [$2] ${3:+- $3}" ;;
    esac
}

# assert_not_contains HAYSTACK NEEDLE
assert_not_contains() {
    case "$1" in
        *"$2"*) _fail "$CURRENT_TEST" "expected output NOT to contain [$2]" ;;
        *) _pass "$CURRENT_TEST" ;;
    esac
}

# assert_true CODE — pass when CODE (a number) is 0
assert_true()  { if [ "$1" -eq 0 ]; then _pass "$CURRENT_TEST"; else _fail "$CURRENT_TEST" "expected exit 0, got $1"; fi; }
# assert_false CODE — pass when CODE is non-zero
assert_false() { if [ "$1" -ne 0 ]; then _pass "$CURRENT_TEST"; else _fail "$CURRENT_TEST" "expected non-zero exit, got 0"; fi; }

# finish — print summary and exit with the right status.
finish() {
    echo "-----------------------------------------------------------------"
    if [ "$TESTS_FAILED" -eq 0 ]; then
        printf "${_C_GRN}PASS${_C_NC}: %d test(s)\n" "$TESTS_RUN"
        exit 0
    else
        printf "${_C_RED}FAIL${_C_NC}: %d of %d test(s) failed\n" "$TESTS_FAILED" "$TESTS_RUN"
        exit 1
    fi
}
