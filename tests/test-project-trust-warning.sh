#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

run_project_enable_test() {
    local trust_value="$1"
    local expect_warning="$2"
    local label="$3"
    local test_dir
    local project_dir
    local project_root
    local notify_stub

    test_dir="$(mktemp -d)"
    project_dir="$test_dir/project"
    notify_stub="$test_dir/notify.sh"

    mkdir -p "$project_dir" "$test_dir/home/.claude"
    (
        cd "$project_dir"
        git init -q
    )
    project_root="$(
        cd "$project_dir"
        git rev-parse --show-toplevel
    )"

    cat > "$test_dir/home/.claude.json" <<JSON
{
  "projects": {
    "$project_root": {
      "hasTrustDialogAccepted": $trust_value
    }
  }
}
JSON

    cat > "$notify_stub" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "$notify_stub"

    (
        export HOME="$test_dir/home"
        export CLAUDE_HOME="$HOME/.claude"
        cd "$project_dir"

        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/help.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/project.sh"

        get_notify_script() {
            echo "$notify_stub"
        }

        output="$(enable_notifications_project 2>&1)"
        echo "$output"

        echo "$output" | grep -q "Project notifications ENABLED" || fail "$label: project notifications were not enabled"
        [[ -f "$project_dir/.claude/settings.json" ]] || fail "$label: project settings were not created"

        if [[ "$expect_warning" == "yes" ]]; then
            echo "$output" | grep -q "trust does not appear to be accepted" || fail "$label: expected trust warning"
        else
            if echo "$output" | grep -q "trust does not appear to be accepted"; then
                fail "$label: unexpected trust warning"
            fi
        fi
    )

    rm -rf "$test_dir"
}

run_project_enable_test "false" "yes" "untrusted project"
pass "warns when Claude project trust has not been accepted"

run_project_enable_test "true" "no" "trusted project"
pass "does not warn when Claude project trust is already accepted"
