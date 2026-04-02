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

run_notifier() {
    local fake_path="$1"
    local subtype="$2"

    printf '{"type":"%s"}\n' "$subtype" | \
        PATH="$fake_path" \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=180 \
        bash "$NOTIFIER" notification claude test-project
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
        echo "SKIP: unsupported OS for notification state-dir test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*

fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"
state_file="$HOME/.claude/notifications/state/last_notification_claude_test-project_idle_prompt"
legacy_file="$HOME/.claude/notifications/last_notification_claude_test-project_idle_prompt"

run_notifier "$fake_path" "idle_prompt"

wait_for_lines "$notification_log" 1 || fail "expected a notification delivery"
[[ -f "$state_file" ]] || fail "rate-limit state file should be written under notifications/state"
[[ ! -f "$legacy_file" ]] || fail "new notifications should not write legacy root-level rate-limit files"

rm -f "$state_file"
date +%s > "$legacy_file"
lines_before=$(wc -l < "$notification_log")

run_notifier "$fake_path" "idle_prompt"

sleep 0.1
lines_after=$(wc -l < "$notification_log")
[[ "$lines_before" -eq "$lines_after" ]] || fail "legacy root-level rate-limit files should still suppress duplicates during upgrade"

printf '%s\n' "0" > "$legacy_file"
run_notifier "$fake_path" "idle_prompt"

wait_for_lines "$notification_log" 2 || fail "expected a notification after legacy state aged out"
[[ -f "$state_file" ]] || fail "fresh writes should recreate the state file under notifications/state"
[[ ! -f "$legacy_file" ]] || fail "fresh writes should clean up legacy root-level rate-limit files"

pass "notification state files move under notifications/state without breaking legacy fallback"
