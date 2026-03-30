#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: click-through is macOS-only"
    exit 0
fi

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir" /tmp/FakeCodex.app' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
notification_log="$test_dir/terminal-notifier.log"
config_file="$HOME/.code-notify/click-through.conf"
fake_app="/tmp/FakeCodex.app"

mkdir -p "$HOME/.code-notify" "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$fake_app/Contents"

cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
chmod +x "$fake_bin/terminal-notifier"

cat > "$fake_app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.fakecodex</string>
</dict>
</plist>
EOF

status_before=$(HOME="$HOME" "$ROOT_DIR/bin/code-notify" click-through status 2>&1 || true)
printf '%s' "$status_before" | grep -q "click-through add" || fail "status should guide users to add a mapping when none exists"

add_output=$(printf 'fake_term\n' | HOME="$HOME" "$ROOT_DIR/bin/code-notify" click-through add "$fake_app" 2>&1)
printf '%s' "$add_output" | grep -q "Saved: TERM_PROGRAM=fake_term" || fail "add should persist the requested TERM_PROGRAM"

[[ -f "$config_file" ]] || fail "click-through config was not created"
grep -q '^fake_term=com.example.fakecodex$' "$config_file" || fail "config file did not store the mapping"

repeat_add_output=$(
    HOME="$HOME" \
    TERM_PROGRAM="fake_term" \
    CODE_NOTIFY_CLICK_THROUGH_APP_PATH="$fake_app" \
    "$ROOT_DIR/bin/code-notify" click-through add 2>&1
)
printf '%s' "$repeat_add_output" | grep -q "Mapping already exists" || fail "auto-detected add should stop when the current app is already mapped"
printf '%s' "$repeat_add_output" | grep -q "click-through remove" || fail "auto-detected add should point users to remove when a mapping already exists"
[[ "$(grep -c '^fake_term=com.example.fakecodex$' "$config_file")" -eq 1 ]] || fail "repeat add should not duplicate an existing mapping"

status_after=$(HOME="$HOME" "$ROOT_DIR/bin/code-notify" click-through status 2>&1)
printf '%s' "$status_after" | grep -q "fake_term" || fail "status should show the saved TERM_PROGRAM"
printf '%s' "$status_after" | grep -q "com.example.fakecodex" || fail "status should show the saved bundle ID"

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
HOME="$HOME" \
TERM_PROGRAM="fake_term" \
bash "$NOTIFIER" test >/dev/null 2>&1

grep -q -- "-activate com.example.fakecodex" "$notification_log" || fail "notifier should activate the configured bundle ID"

remove_output=$(printf ' \n' | HOME="$HOME" "$ROOT_DIR/bin/code-notify" click-through remove 2>&1)
printf '%s' "$remove_output" | grep -q "Removed 1 mapping" || fail "interactive remove should delete the selected mapping"
printf '%s' "$remove_output" | grep -q "fake_term" || fail "interactive remove should report the removed TERM_PROGRAM"

status_final=$(HOME="$HOME" "$ROOT_DIR/bin/code-notify" click-through status 2>&1 || true)
printf '%s' "$status_final" | grep -q "No click-through mappings found" || fail "status should return to the empty-state message after removal"

printf 'fake_term\n' | HOME="$HOME" "$ROOT_DIR/bin/code-notify" click-through add "$fake_app" >/dev/null 2>&1
cancel_output=$(printf 'q' | HOME="$HOME" "$ROOT_DIR/bin/code-notify" click-through remove 2>&1 || true)
printf '%s' "$cancel_output" | grep -q "Cancelled" || fail "interactive remove should allow quitting without changes"
grep -q '^fake_term=com.example.fakecodex$' "$config_file" || fail "quit should leave the existing mapping intact"

pass "click-through commands manage mappings, interactive removal, and notifier activation"
