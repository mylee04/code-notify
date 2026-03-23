#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

homebrew_method=$(detect_update_method "/opt/homebrew/Cellar/code-notify/1.6.4/lib/code-notify/commands")
[[ "$homebrew_method" == "homebrew" ]] || fail "expected homebrew update method"
pass "detects Homebrew installations"

script_method=$(detect_update_method "$HOME/.code-notify/lib/code-notify/commands")
[[ "$script_method" == "script" ]] || fail "expected install-script update method"
pass "detects install-script installations"

manual_method=$(detect_update_method "$SCRIPT_DIR/../lib/code-notify/commands")
[[ "$manual_method" == "manual" ]] || fail "expected manual update method"
pass "detects local checkout/manual installations"

script_command=$(get_update_command "script")
[[ "$script_command" == "curl -fsSL https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install.sh | bash" ]] || fail "unexpected install-script update command"
pass "uses the correct mylee04 install script URL"

homebrew_command=$(get_update_command "homebrew")
[[ "$homebrew_command" == "brew update && brew upgrade code-notify" ]] || fail "unexpected Homebrew update command"
pass "uses the correct Homebrew update command"

if "$SCRIPT_DIR/../bin/code-notify" update check 2>&1 | grep -q "Local checkout or unsupported install method detected"; then
    pass "update check handles local checkouts without mutating files"
else
    fail "update check did not report manual/local checkout guidance"
fi
