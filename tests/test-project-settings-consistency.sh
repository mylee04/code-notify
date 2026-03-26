#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
mkdir -p "$HOME/.claude" "$test_dir/project/.claude"

cat > "$test_dir/project/.claude/settings.json" <<'EOF'
{
  "model": "sonnet",
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/notifier.sh notification claude demo-project"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/notifier.sh stop claude demo-project"
          }
        ]
      }
    ]
  }
}
EOF

cat > "$test_dir/project/.claude/hooks.json" <<'EOF'
{
  "hooks": {
    "stop": {
      "command": "/tmp/legacy-notify.sh"
    }
  }
}
EOF

(
    cd "$test_dir/project"
    source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
    source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
    source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
    source "$SCRIPT_DIR/../lib/code-notify/commands/project.sh"

    status_output="$(show_project_status 2>&1)"
    echo "$status_output" | grep -q ".claude/settings.json" || fail "project status should report settings.json for the current config"
    if echo "$status_output" | grep -q ".claude/hooks.json"; then
        fail "project status should not prefer legacy hooks.json when settings.json is active"
    fi

    disable_output="$(disable_notifications_project 2>&1)" || fail "project disable command failed"
    echo "$disable_output" | grep -q "Project notifications DISABLED" || fail "project disable should report success for settings.json-based configs"

    [[ ! -f "$test_dir/project/.claude/hooks.json" ]] || fail "legacy hooks.json should be removed during project disable"
    grep -q '"model": "sonnet"' "$test_dir/project/.claude/settings.json" || fail "project disable should preserve non-hook settings"
    if grep -q '"hooks"' "$test_dir/project/.claude/settings.json"; then
        fail "project disable should remove hooks from settings.json"
    fi
)

pass "project status and disable stay aligned with settings.json-based project hooks"
