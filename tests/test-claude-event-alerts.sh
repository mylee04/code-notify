#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CLAUDE_HOME="$HOME/.claude"
export CLAUDE_SETTINGS_HOME="$CLAUDE_HOME"
mkdir -p "$CLAUDE_HOME/notifications"

source "$ROOT_DIR/lib/code-notify/core/config.sh"

notify_script="$test_dir/notify.sh"
get_notify_script() {
    printf '%s\n' "$notify_script"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_settings() {
    python3 - "$GLOBAL_SETTINGS_FILE" "$notify_script" <<'PYTHON'
import json
import sys

settings_file, notify_script = sys.argv[1:3]
with open(settings_file, "r") as fh:
    settings = json.load(fh)

hooks = settings.get("hooks", {})

def has_command(event, matcher, command):
    for entry in hooks.get(event, []):
        if entry.get("matcher", "") != matcher:
            continue
        for hook in entry.get("hooks", []):
            if hook.get("type") == "command" and hook.get("command") == command:
                return True
    return False

expected = {
    "Notification": ("idle_prompt", f"{notify_script} notification claude"),
    "Stop": ("", f"{notify_script} stop claude"),
    "SubagentStop": ("", f"{notify_script} SubagentStop claude"),
    "TeammateIdle": ("", f"{notify_script} TeammateIdle claude"),
    "TaskCompleted": ("", f"{notify_script} TaskCompleted claude"),
}

for event, (matcher, command) in expected.items():
    if not has_command(event, matcher, command):
        raise SystemExit(f"missing {event} command: {command}")

unexpected = {"SubagentStart", "TaskCreated"}
for event in unexpected:
    if event in hooks:
        raise SystemExit(f"unexpected hook installed: {event}")
PYTHON
}

set_notify_types "idle_prompt|subagent_stop|teammate-idle|TaskCompleted"
[[ "$(get_notify_types)" == "idle_prompt|SubagentStop|TeammateIdle|TaskCompleted" ]] ||
    fail "alert types were not normalized"

enable_hooks_in_settings
assert_settings
has_current_global_claude_hooks "$GLOBAL_SETTINGS_FILE" ||
    fail "current hook detection should include Claude event hooks"

remove_notify_type "idle_prompt"
[[ "$(get_notify_matcher)" == "" ]] || fail "notification matcher should be empty after removing the last Notification subtype"
enable_hooks_in_settings

python3 - "$GLOBAL_SETTINGS_FILE" "$notify_script" <<'PYTHON'
import json
import sys

settings_file, notify_script = sys.argv[1:3]
with open(settings_file, "r") as fh:
    hooks = json.load(fh).get("hooks", {})

if "Notification" in hooks:
    raise SystemExit("Notification hook should not be installed for event-only alert config")

for event in ("SubagentStop", "TeammateIdle", "TaskCompleted"):
    command = f"{notify_script} {event} claude"
    if not any(
        hook.get("command") == command
        for entry in hooks.get(event, [])
        for hook in entry.get("hooks", [])
    ):
        raise SystemExit(f"missing event command: {command}")
PYTHON

disable_hooks_in_settings
[[ ! -f "$GLOBAL_SETTINGS_FILE" ]] || fail "managed event hooks should be removed on disable"

echo "PASS: Claude event alert hooks"
