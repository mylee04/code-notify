#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"
NPM_CN="$SCRIPT_DIR/../bin/npm-cn.js"

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
export CLAUDE_HOME="$HOME/.claude"
export CLAUDE_SETTINGS_HOME="$CLAUDE_HOME"
export CODEX_HOME="$HOME/.codex"
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

if command -v node >/dev/null 2>&1; then
    ln -s /usr/bin/true "$fake_bin/codex"
    delivery_log="$HOME/.claude/logs/notifications.log"

    # Enable Codex while the existing all-tools mute is active.
    PATH="$fake_bin:$PATH" node "$NPM_CN" on codex >/dev/null
    [[ -f "$HOME/.codex/config.toml" ]] || fail "cn on codex did not configure Codex"
    [[ ! -f "$HOME/.claude/settings.json" ]] || fail "cn on codex wrote Claude settings"
    PATH="$fake_path" bash "$NOTIFIER" stop claude
    PATH="$fake_path" bash "$NOTIFIER" codex '{"type":"agent-turn-complete"}'
    [[ $(wc -l < "$delivery_log") -eq 2 ]] || fail "cn on codex should only unmute Codex"
    tail -1 "$delivery_log" | grep -q '\[codex\]' || fail "Codex stayed muted after cn on codex"

    # Once Claude is enabled, toggling Codex must leave Claude delivery active.
    PATH="$fake_bin:$PATH" node "$NPM_CN" on claude >/dev/null
    PATH="$fake_bin:$PATH" node "$NPM_CN" off codex >/dev/null
    PATH="$fake_path" CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 bash "$NOTIFIER" codex '{"type":"agent-turn-complete"}'
    PATH="$fake_path" CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 bash "$NOTIFIER" stop claude
    [[ $(wc -l < "$delivery_log") -eq 3 ]] || fail "cn off codex should only mute Codex"
    tail -1 "$delivery_log" | grep -q '\[claude\]' || fail "cn off codex muted Claude"
    pass "npm cn on and off keep Codex and Claude notification mutes independent"
fi
