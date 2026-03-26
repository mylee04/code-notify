#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

wait_for_lines() {
    local file="$1"
    local expected_lines="$2"

    for _ in $(seq 1 40); do
        if [[ -f "$file" ]] && [[ $(wc -l < "$file") -ge "$expected_lines" ]]; then
            return 0
        fi
        sleep 0.05
    done

    return 1
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$log_dir"
touch "$HOME/.claude/notifications/disabled"

case "$(uname -s)" in
    Darwin)
        notification_log="$log_dir/terminal-notifier.log"
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        ;;
    Linux)
        notification_log="$log_dir/notify-send.log"
        cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        ;;
    *)
        echo "SKIP: unsupported OS for project kill switch test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

PATH="$fake_path" bash "$NOTIFIER" notification claude

if [[ -f "$notification_log" ]] && [[ -s "$notification_log" ]]; then
    fail "global notifications should still be suppressed by the kill switch"
fi

PATH="$fake_path" bash "$NOTIFIER" notification claude demo-project

wait_for_lines "$notification_log" 1 || fail "project-scoped notification should bypass the global kill switch"
grep -q "demo-project" "$notification_log" || fail "project-scoped notification did not include the project name"

pass "project-scoped hooks bypass the global kill switch while global hooks stay muted"
