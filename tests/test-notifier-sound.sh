#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: macOS-specific sound test"
    exit 0
fi

wait_for_log() {
    local file="$1"
    for _ in $(seq 1 40); do
        if [[ -f "$file" ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

run_case() {
    local mode="$1"
    local test_dir
    local fake_bin
    local log_dir

    test_dir="$(mktemp -d)"
    trap 'rm -rf "$test_dir"' RETURN

    export HOME="$test_dir/home"
    fake_bin="$test_dir/bin"
    log_dir="$test_dir/log"
    mkdir -p "$HOME/.claude/notifications" "$fake_bin" "$log_dir"

    touch "$test_dir/custom.aiff"
    : > "$HOME/.claude/notifications/sound-enabled"
    printf '%s\n' "$test_dir/custom.aiff" > "$HOME/.claude/notifications/sound-custom"

    cat > "$fake_bin/afplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$log_dir/afplay.log"
EOF
    chmod +x "$fake_bin/afplay"

    if [[ "$mode" == "terminal-notifier" ]]; then
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$log_dir/terminal-notifier.log"
EOF
        chmod +x "$fake_bin/terminal-notifier"
    else
        cat > "$fake_bin/osascript" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$log_dir/osascript.log"
EOF
        chmod +x "$fake_bin/osascript"
    fi

    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" bash "$NOTIFIER" stop claude

    wait_for_log "$log_dir/afplay.log" || fail "$mode did not invoke afplay"
    [[ $(wc -l < "$log_dir/afplay.log") -eq 1 ]] || fail "$mode invoked afplay more than once"

    if [[ "$mode" == "terminal-notifier" ]]; then
        wait_for_log "$log_dir/terminal-notifier.log" || fail "terminal-notifier path did not run"
        if grep -q -- '-sound' "$log_dir/terminal-notifier.log"; then
            fail "terminal-notifier path still requests OS notification sound"
        fi
    else
        wait_for_log "$log_dir/osascript.log" || fail "osascript path did not run"
        if grep -q 'sound name' "$log_dir/osascript.log"; then
            fail "osascript path still requests OS notification sound"
        fi
    fi

    pass "$mode uses only the configured sound playback path"
    rm -rf "$test_dir"
    trap - RETURN
}

run_case "terminal-notifier"
run_case "osascript"
