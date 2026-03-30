#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: click-through resolver is macOS-only"
    exit 0
fi

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
config_file="$HOME/.code-notify/click-through.conf"
apps_dir="$HOME/Applications"
pycharm_app="$apps_dir/PyCharm.app"

mkdir -p "$HOME/.code-notify" "$pycharm_app/Contents"

cat > "$pycharm_app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.jetbrains.pycharm</string>
</dict>
</plist>
EOF

source "$ROOT_DIR/lib/code-notify/utils/click-through-store.sh"
source "$ROOT_DIR/lib/code-notify/utils/click-through-runtime.sh"
source "$ROOT_DIR/lib/code-notify/utils/click-through-resolver.sh"

[[ "$(click_through_lookup_builtin_bundle_id "ghostty")" == "com.mitchellh.ghostty" ]] || fail "builtin key lookup should use the canonical mapping table"
[[ "$(click_through_lookup_builtin_term_program "com.github.wez.wezterm")" == "WezTerm" ]] || fail "builtin reverse lookup should use the canonical mapping table"

cat > "$config_file" <<'EOF'
# Code-Notify click-through configuration
# Maps TERM_PROGRAM values to macOS bundle IDs

JetBrains-JediTerm=com.jetbrains.pycharm
EOF

unset __CFBundleIdentifier

TERM_PROGRAM="JetBrains-JediTerm"
[[ "$(click_through_resolve_configured_bundle_id)" == "com.jetbrains.pycharm" ]] || fail "configured resolution should prefer the live TERM_PROGRAM"

TERM_PROGRAM=""
CODE_NOTIFY_CLICK_THROUGH_APP_PATH="$pycharm_app"
[[ "$(click_through_resolve_configured_bundle_id)" == "com.jetbrains.pycharm" ]] || fail "configured resolution should fall back to the current app bundle ID"

rm -f "$config_file"

TERM_PROGRAM="cursor"
CODE_NOTIFY_CLICK_THROUGH_APP_PATH=""
[[ "$(click_through_resolve_activation_bundle_id)" == "com.todesktop.230313mzl4w4u92" ]] || fail "activation resolution should fall back to built-in TERM_PROGRAM mappings"

TERM_PROGRAM="JetBrains-JediTerm"
[[ "$(click_through_resolve_default_term_program "com.jetbrains.pycharm" "PyCharm")" == "JetBrains-JediTerm" ]] || fail "default TERM_PROGRAM should prefer the live runtime value"

TERM_PROGRAM=""
[[ "$(click_through_resolve_default_term_program "com.github.wez.wezterm" "WezTerm")" == "WezTerm" ]] || fail "default TERM_PROGRAM should fall back to builtin reverse lookup"

[[ "$(click_through_resolve_default_term_program "com.example.fakecodex" "Fake Codex")" == "fake_codex" ]] || fail "default TERM_PROGRAM should normalize unknown app names"

pass "click-through resolver keeps a single mapping source and stable resolution order"
