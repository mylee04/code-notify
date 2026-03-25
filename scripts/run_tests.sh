#!/bin/bash

# Simple test suite for Code-Notify

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test functions
test_start() {
    echo -n "Testing $1... "
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
    echo -e "${GREEN}PASS${RESET}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Change to project root
cd "$(dirname "$0")/.."
CURRENT_VERSION="$(awk -F'"' '/^VERSION=/{print $2}' bin/code-notify)"

# Test 1: Main executable exists and is executable
test_start "main executable exists"
if [[ -x "bin/code-notify" ]]; then
    test_pass
else
    test_fail "bin/code-notify not found or not executable"
fi

# Test 2: Can show version
test_start "version command"
if ./bin/code-notify version 2>&1 | grep -q "version"; then
    test_pass
else
    test_fail "version command failed"
fi

# Test 3: Can show help
test_start "help command"
if ./bin/code-notify help 2>&1 | grep -q "USAGE"; then
    test_pass
else
    test_fail "help command failed"
fi

# Test 4: Library files exist
test_start "library files"
if [[ -f "lib/code-notify/utils/colors.sh" ]] && \
   [[ -f "lib/code-notify/utils/detect.sh" ]] && \
   [[ -f "lib/code-notify/core/config.sh" ]]; then
    test_pass
else
    test_fail "missing library files"
fi

# Test 5: Command routing (cn alias simulation)
test_start "cn command routing"
if CN_TEST=1 ./bin/code-notify help 2>&1 | grep -q "Code-Notify"; then
    test_pass
else
    test_fail "command routing failed"
fi

# Test 6: Check syntax of all shell scripts
test_start "shell script syntax"
SYNTAX_ERROR=0
for script in bin/code-notify lib/code-notify/**/*.sh; do
    if [[ -f "$script" ]]; then
        if ! bash -n "$script" 2>/dev/null; then
            SYNTAX_ERROR=1
            echo -e "\n  ${YELLOW}Syntax error in: $script${RESET}"
        fi
    fi
done
if [[ $SYNTAX_ERROR -eq 0 ]]; then
    test_pass
else
    test_fail "syntax errors found"
fi

# Test 7: update command is exposed in help
test_start "update command in help"
if ./bin/code-notify help 2>&1 | grep -q "update"; then
    test_pass
else
    test_fail "update command missing from help"
fi

# Test 8: update check command works
test_start "update check command"
if CODE_NOTIFY_INSTALL_METHOD=script CODE_NOTIFY_LATEST_VERSION="$CURRENT_VERSION" ./bin/code-notify update check 2>&1 | grep -q "Code-Notify is up to date"; then
    test_pass
else
    test_fail "update check command failed"
fi

# Test 9: update command skips reinstalling current versions
test_start "no-op update command"
if CODE_NOTIFY_INSTALL_METHOD=script CODE_NOTIFY_LATEST_VERSION="$CURRENT_VERSION" ./bin/code-notify update 2>&1 | grep -q "Code-Notify is up to date"; then
    test_pass
else
    test_fail "update command did not skip reinstalling the current version"
fi

# Test 10: project enable warns when Claude trust is missing
test_start "project trust warning"
if bash tests/test-project-trust-warning.sh >/dev/null 2>&1; then
    test_pass
else
    test_fail "project trust warning behavior failed"
fi

# Test 11: explicit all aliases map to global behavior
test_start "all tool aliases"
if bash tests/test-all-alias.sh >/dev/null 2>&1; then
    test_pass
else
    test_fail "all aliases failed"
fi

# Test 12: npm launchers can route to the shell runtime
test_start "npm launcher routing"
if node ./bin/npm-cn.js version 2>&1 | grep -q "code-notify version"; then
    test_pass
else
    test_fail "npm launcher version command failed"
fi

# Test 13: repeated notification states are deduped
test_start "notification dedupe"
if bash tests/test-notification-dedupe.sh >/dev/null 2>&1; then
    test_pass
else
    test_fail "notification dedupe failed"
fi

# Test 14: Codex payloads are parsed into notifications correctly
test_start "codex payload parsing"
if bash tests/test-codex-notify.sh >/dev/null 2>&1; then
    test_pass
else
    test_fail "codex payload parsing failed"
fi

# Test 15: Windows PowerShell status regex stays .NET-safe
test_start "windows status regex"
if bash tests/test-windows-status-regex.sh >/dev/null 2>&1; then
    test_pass
else
    test_fail "windows status regex failed"
fi

# Summary
echo ""
echo "Test Summary:"
echo "============="
echo -e "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${RESET}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${RESET}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${RESET}"
    exit 0
else
    echo -e "\n${RED}Some tests failed!${RESET}"
    exit 1
fi
