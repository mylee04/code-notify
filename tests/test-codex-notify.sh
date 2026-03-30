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

run_codex_notifier() {
    local fake_path="$1"
    local payload="$2"

    PATH="$fake_path" \
    CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=180 \
    CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 \
    bash "$NOTIFIER" codex "$payload"
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
sound_file="$test_dir/custom.aiff"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$log_dir"

touch "$sound_file"
: > "$HOME/.claude/notifications/sound-enabled"
printf '%s\n' "$sound_file" > "$HOME/.claude/notifications/sound-custom"

case "$(uname -s)" in
    Darwin)
        notification_log="$log_dir/terminal-notifier.log"
        sound_log="$log_dir/afplay.log"
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        cat > "$fake_bin/afplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sound_log"
EOF
        ;;
    Linux)
        notification_log="$log_dir/notify-send.log"
        sound_log="$log_dir/paplay.log"
        cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        cat > "$fake_bin/paplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sound_log"
EOF
        ;;
    *)
        echo "SKIP: unsupported OS for Codex notify test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*

fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","cwd":"/tmp/demo","client":"codex-exec","input-messages":["Run tests"],"last-assistant-message":"All tests passed"}'
run_codex_notifier "$fake_path" '{"type":"request_permissions","cwd":"/tmp/demo","tool":"exec_command"}'

wait_for_lines "$notification_log" 2 || fail "expected two Codex notification deliveries"
wait_for_lines "$sound_log" 2 || fail "expected two Codex sound playbacks"
wait_for_lines "$HOME/.claude/logs/notifications.log" 2 || fail "expected two Codex notification log entries"

grep -q "Task Complete - demo" "$notification_log" || fail "Codex completion payload did not map to a stop notification"
grep -q "Input Required - demo" "$notification_log" || fail "Codex permission-like payload did not map to an input-required notification"

pass "Codex payload parsing maps completion and permission-like payloads to the expected notification types"
