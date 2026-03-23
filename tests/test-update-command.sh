#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(awk -F'"' '/^VERSION=/{print $2}' "$SCRIPT_DIR/../bin/code-notify")"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

homebrew_method=$(detect_update_method "/opt/homebrew/Cellar/code-notify/$VERSION/lib/code-notify/commands")
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

same_version=$(compare_versions "1.6.4" "1.6.4")
[[ "$same_version" == "0" ]] || fail "expected equal versions to compare as 0"
pass "compares identical versions"

newer_version=$(compare_versions "1.6.5" "1.6.4")
[[ "$newer_version" == "1" ]] || fail "expected newer version to compare as 1"
pass "compares newer versions"

older_version=$(compare_versions "1.6.4" "1.6.5")
[[ "$older_version" == "-1" ]] || fail "expected older version to compare as -1"
pass "compares older versions"

latest_override=$(CODE_NOTIFY_LATEST_VERSION="v9.9.9" get_latest_release_version)
[[ "$latest_override" == "9.9.9" ]] || fail "expected latest release override to normalize the version"
pass "normalizes the latest release version override"

script_check_output=$(CODE_NOTIFY_INSTALL_METHOD="script" CODE_NOTIFY_LATEST_VERSION="$VERSION" "$SCRIPT_DIR/../bin/code-notify" update check 2>&1)
echo "$script_check_output" | grep -q "Already up to date" || fail "expected script update check to report an up-to-date install"
echo "$script_check_output" | grep -q "scripts/install.sh" || fail "expected script update check to show the install script command"
pass "update check reports when script installs are already current"

outdated_check_output=$(CODE_NOTIFY_INSTALL_METHOD="script" CODE_NOTIFY_LATEST_VERSION="9.9.9" "$SCRIPT_DIR/../bin/code-notify" update check 2>&1)
echo "$outdated_check_output" | grep -q "Update available: $VERSION -> 9.9.9" || fail "expected script update check to report when an update is available"
pass "update check reports when script installs are behind the latest release"

noop_update_output=$(CODE_NOTIFY_INSTALL_METHOD="script" CODE_NOTIFY_LATEST_VERSION="$VERSION" "$SCRIPT_DIR/../bin/code-notify" update 2>&1)
echo "$noop_update_output" | grep -q "Already up to date" || fail "expected update command to skip reinstalling the current version"
if echo "$noop_update_output" | grep -q "Update complete!"; then
    fail "expected update command to skip the reinstall path when already current"
fi
pass "update command skips reinstalling script installs that are already current"

if "$SCRIPT_DIR/../bin/code-notify" update check 2>&1 | grep -q "Local checkout or unsupported install method detected"; then
    pass "update check handles local checkouts without mutating files"
else
    fail "update check did not report manual/local checkout guidance"
fi
