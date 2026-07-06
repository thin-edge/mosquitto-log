#!/usr/bin/env bash
# Assertion + reporting helpers for the Docker functional test suite.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

if [ -t 1 ]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

pass() {
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ${C_GREEN}✓${C_RESET} $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED_NAMES+=("$1")
    echo "  ${C_RED}✗${C_RESET} $1"
    [ -n "${2:-}" ] && echo "      ${C_DIM}$2${C_RESET}"
    return 0
}

# assert_contains <name> <literal-needle> <haystack>
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        pass "$1"
    else
        fail "$1" "expected to find: $2"
    fi
}

# assert_not_contains <name> <literal-needle> <haystack>
assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        fail "$1" "did not expect: $2"
    else
        pass "$1"
    fi
}

summary() {
    echo ""
    echo "${C_BOLD}${TESTS_PASSED}/${TESTS_RUN} checks passed${C_RESET}"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo "${C_RED}${TESTS_FAILED} failed:${C_RESET}"
        printf '  - %s\n' "${FAILED_NAMES[@]}"
        return 1
    fi
    echo "${C_GREEN}All checks passed.${C_RESET}"
    return 0
}
