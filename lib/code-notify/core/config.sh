#!/bin/bash

# Configuration management for Code-Notify

# Default paths - Claude Code
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
GLOBAL_SETTINGS_FILE="$CLAUDE_HOME/settings.json"
GLOBAL_HOOKS_FILE="$CLAUDE_HOME/hooks.json"  # Legacy support
GLOBAL_HOOKS_DISABLED="$CLAUDE_HOME/hooks.json.disabled"
CONFIG_DIR="$HOME/.config/code-notify"
CONFIG_FILE="$CONFIG_DIR/config.json"
BACKUP_DIR="$CONFIG_DIR/backups"

# Project-level settings
PROJECT_SETTINGS_FILE=".claude/settings.json"
PROJECT_SETTINGS_LOCAL_FILE=".claude/settings.local.json"

# Notification types configuration
NOTIFY_TYPES_FILE="$HOME/.claude/notifications/notify-types"
DEFAULT_NOTIFY_TYPE="idle_prompt"

# Available notification types:
# - idle_prompt: AI is waiting for user input (after 60+ seconds idle)
# - permission_prompt: AI needs permission to use a tool
# - auth_success: Authentication success notifications
# - elicitation_dialog: MCP tool input needed

# Codex paths
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG_FILE="$CODEX_HOME/config.toml"

# Gemini CLI paths
GEMINI_HOME="${GEMINI_HOME:-$HOME/.gemini}"
GEMINI_SETTINGS_FILE="$GEMINI_HOME/settings.json"

# Ensure config directory exists
ensure_config_dir() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
}

# --- JSON Helper Functions ---

# Check if jq is available
has_jq() {
    command -v jq &> /dev/null
}

# Check if python3 is available
has_python3() {
    command -v python3 &> /dev/null
}

# Shell quote helper - safely escape strings for shell commands
# Usage: shell_quote "string with spaces; and special chars"
# Returns: properly quoted string safe for shell execution
shell_quote() {
    local str="$1"
    printf '%q' "$str"
}

# Atomic file write helper - prevents data loss on crash
atomic_write() {
    local target="$1"
    local content="$2"
    local dir_path
    local tmp_file

    dir_path=$(dirname "$target")
    tmp_file=$(mktemp "${dir_path}/.tmp.XXXXXX") || return 1

    if printf '%s\n' "$content" > "$tmp_file"; then
        mv "$tmp_file" "$target"
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# Escape a string for use inside a TOML basic string.
toml_escape_string() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    printf '%s' "$str"
}

# Check whether a key exists at TOML top-level (before the first table header).
toml_has_top_level_key() {
    local file="$1"
    local key="$2"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    awk -v key="$key" '
        $0 ~ /^[[:space:]]*\[/ {
            exit(found ? 0 : 1)
        }
        $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$file"
}

# Insert Code-Notify's top-level notify key before the first TOML table.
upsert_codex_notify_config() {
    local file="$1"
    local notify_line="$2"
    local dir_path
    local tmp_file

    dir_path=$(dirname "$file")
    tmp_file=$(mktemp "${dir_path}/.tmp.XXXXXX") || return 1

    awk -v comment_line="# Code-Notify: Desktop notifications" -v notify_line="$notify_line" '
        /^[[:space:]]*# Code-Notify: Desktop notifications[[:space:]]*$/ {
            next
        }
        /^[[:space:]]*notify[[:space:]]*=/ {
            next
        }
        !inserted && $0 ~ /^[[:space:]]*\[/ {
            while (prefix_count > 0 && prefix[prefix_count] ~ /^[[:space:]]*$/) {
                prefix_count--
            }
            for (i = 1; i <= prefix_count; i++) {
                print prefix[i]
            }
            if (prefix_count > 0) {
                print ""
            }
            print comment_line
            print notify_line
            print ""
            print
            inserted = 1
            next
        }
        !inserted {
            prefix[++prefix_count] = $0
            next
        }
        {
            print
        }
        END {
            if (!inserted) {
                while (prefix_count > 0 && prefix[prefix_count] ~ /^[[:space:]]*$/) {
                    prefix_count--
                }
                for (i = 1; i <= prefix_count; i++) {
                    print prefix[i]
                }
                if (prefix_count > 0) {
                    print ""
                }
                print comment_line
                print notify_line
            }
        }
    ' "$file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    mv "$tmp_file" "$file"
}

# Safe jq update helper - applies jq filter and only writes on success
# Usage: safe_jq_update <file> <jq_filter> [--arg name value]...
# Returns 0 on success, 1 on failure (original file unchanged)
safe_jq_update() {
    local file="$1"
    local jq_filter="$2"
    shift 2

    # Read existing content
    local content="{}"
    if [[ -f "$file" ]]; then
        content=$(cat "$file")
    fi

    # Apply jq filter
    local new_content
    if ! new_content=$(echo "$content" | jq "$@" "$jq_filter" 2>/dev/null); then
        echo "Error: Failed to parse or update configuration JSON" >&2
        echo "File unchanged: $file" >&2
        return 1
    fi

    # Validate result is not empty
    if [[ -z "$new_content" ]]; then
        echo "Error: jq produced empty output, file unchanged" >&2
        return 1
    fi

    # Atomic write
    atomic_write "$file" "$new_content"
}

# Validate JSON file format
validate_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    if has_jq; then
        jq empty "$file" 2>/dev/null
    else
        # Basic validation: check for balanced braces
        grep -q '{' "$file" && grep -q '}' "$file"
    fi
}

# Check if JSON path exists (returns 0 if exists)
json_has() {
    local file="$1"
    local jq_path="$2"
    local grep_pattern="$3"

    if [[ ! -f "$file" ]]; then
        return 1
    fi
    if has_jq; then
        jq -e "$jq_path" "$file" &>/dev/null
    else
        grep -qE "$grep_pattern" "$file" 2>/dev/null
    fi
}

# Check if file has code-notify specific hooks (Notification or Stop)
has_claude_notify_hooks() {
    local file="$1"
    json_has "$file" '(.hooks.Notification != null) or (.hooks.Stop != null)' '"(Notification|Stop)"'
}

get_global_claude_notify_command() {
    printf '%s notification claude\n' "$(get_notify_script)"
}

get_global_claude_stop_command() {
    printf '%s stop claude\n' "$(get_notify_script)"
}

has_current_global_claude_hooks() {
    local file="$1"
    local matcher notify_cmd stop_cmd

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    matcher=$(get_notify_matcher)
    notify_cmd=$(get_global_claude_notify_command)
    stop_cmd=$(get_global_claude_stop_command)

    if has_jq; then
        jq -e \
            --arg matcher "$matcher" \
            --arg notify "$notify_cmd" \
            --arg stop "$stop_cmd" \
            '
            (.hooks.Notification | type == "array" and length > 0) and
            (.hooks.Stop | type == "array" and length > 0) and
            .hooks.Notification[0].matcher == $matcher and
            .hooks.Notification[0].hooks[0].type == "command" and
            .hooks.Notification[0].hooks[0].command == $notify and
            .hooks.Stop[0].matcher == "" and
            .hooks.Stop[0].hooks[0].type == "command" and
            .hooks.Stop[0].hooks[0].command == $stop
            ' "$file" >/dev/null 2>&1
        return $?
    fi

    if has_python3; then
        python3 - "$file" "$matcher" "$notify_cmd" "$stop_cmd" << 'PYTHON'
import json
import sys

file_path, matcher, notify_cmd, stop_cmd = sys.argv[1:5]

with open(file_path, "r") as fh:
    settings = json.load(fh)

notification = settings.get("hooks", {}).get("Notification", [])
stop = settings.get("hooks", {}).get("Stop", [])

assert isinstance(notification, list) and notification
assert isinstance(stop, list) and stop
assert notification[0].get("matcher", "") == matcher
assert notification[0].get("hooks", [{}])[0].get("type") == "command"
assert notification[0].get("hooks", [{}])[0].get("command") == notify_cmd
assert stop[0].get("matcher", "") == ""
assert stop[0].get("hooks", [{}])[0].get("type") == "command"
assert stop[0].get("hooks", [{}])[0].get("command") == stop_cmd
PYTHON
        return $?
    fi

    grep -qF "\"matcher\": \"$matcher\"" "$file" &&
        grep -qF "\"command\": \"$notify_cmd\"" "$file" &&
        grep -qF "\"command\": \"$stop_cmd\"" "$file"
}

has_legacy_global_claude_hooks() {
    local file="${1:-$GLOBAL_SETTINGS_FILE}"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    grep -q 'claude-notify' "$file" ||
        grep -qE 'notifier\.sh (notification|stop)"' "$file" ||
        grep -q 'notifier.sh PreToolUse' "$file"
}

claude_global_hooks_need_repair() {
    has_legacy_global_claude_hooks "$GLOBAL_SETTINGS_FILE"
}

repair_legacy_hooks_command() {
    local quiet="${1:-}"
    local repaired=0

    if claude_global_hooks_need_repair; then
        if ! enable_hooks_in_settings; then
            if [[ "$quiet" != "--quiet" ]]; then
                echo "Failed to repair legacy Claude hooks" >&2
            fi
            return 1
        fi
        repaired=1

        if [[ "$quiet" != "--quiet" ]]; then
            echo "Repaired legacy Claude hooks in $GLOBAL_SETTINGS_FILE"
        fi
    fi

    if [[ $repaired -eq 0 ]] && [[ "$quiet" != "--quiet" ]]; then
        echo "No legacy hooks required repair"
    fi

    return 0
}

# Check if file has any hooks
has_any_hooks() {
    local file="$1"
    json_has "$file" '.hooks != null' '"hooks"'
}

# Get hooks file path (project or global)
get_hooks_file() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_hooks="$project_root/.claude/hooks.json"
    
    # Check for project-specific hooks first
    if [[ -f "$project_hooks" ]]; then
        echo "$project_hooks"
        return 0
    fi
    
    # Fall back to global hooks
    echo "$GLOBAL_HOOKS_FILE"
}

# Check if notifications are enabled
is_enabled() {
    local hooks_file=$(get_hooks_file)
    [[ -f "$hooks_file" ]]
}

# Check if notifications are enabled globally
is_enabled_globally() {
    # Check new settings.json format first
    if has_claude_notify_hooks "$GLOBAL_SETTINGS_FILE"; then
        return 0
    fi
    # Fall back to legacy hooks.json
    [[ -f "$GLOBAL_HOOKS_FILE" ]]
}

# Check if notifications are enabled for current project
is_enabled_project() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_settings="$project_root/.claude/settings.json"
    local project_hooks="$project_root/.claude/hooks.json"
    
    # Check new format first
    if is_enabled_project_settings; then
        return 0
    fi
    # Fall back to legacy format
    [[ -f "$project_hooks" ]]
}

# Create default hooks configuration
create_default_hooks() {
    local target_file="${1:-$GLOBAL_HOOKS_FILE}"
    local project_name="${2:-}"
    
    cat > "$target_file" << EOF
{
  "hooks": {
    "stop": {
      "description": "Notify when Claude completes a task",
      "command": "~/.claude/notifications/notify.sh stop completed '${project_name}'"
    },
    "notification": {
      "description": "Notify when Claude needs input",
      "command": "~/.claude/notifications/notify.sh notification required '${project_name}'"
    }
  }
}
EOF
}

# Backup existing configuration
backup_config() {
    local file="$1"
    if [[ -f "$file" ]]; then
        # Ensure backup directory exists
        if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
            echo "Warning: Failed to create backup directory: $BACKUP_DIR" >&2
            return 1
        fi

        local backup_name="$(basename "$file").$(date +%Y%m%d_%H%M%S)"
        if cp "$file" "$BACKUP_DIR/$backup_name" 2>/dev/null; then
            return 0
        else
            echo "Warning: Failed to create backup of $file" >&2
            return 1
        fi
    fi
    return 1
}

# Get notification script path
get_notify_script() {
    # First check if installed via Homebrew
    if [[ -f "/usr/local/opt/code-notify/lib/code-notify/core/notifier.sh" ]]; then
        echo "/usr/local/opt/code-notify/lib/code-notify/core/notifier.sh"
    # Then check home directory
    elif [[ -f "$HOME/.claude/notifications/notify.sh" ]]; then
        echo "$HOME/.claude/notifications/notify.sh"
    # Finally check relative to this script
    else
        echo "$(dirname "${BASH_SOURCE[0]}")/notifier.sh"
    fi
}

# Validate hooks file format
validate_hooks_file() {
    local file="$1"
    validate_json "$file" && has_any_hooks "$file"
}

# Get current configuration status
get_status_info() {
    local status_info=""
    
    # Global status
    if is_enabled_globally; then
        status_info="${status_info}${BELL} Global notifications: ${GREEN}ENABLED${RESET}\n"
        # Check which config file is being used
        if has_any_hooks "$GLOBAL_SETTINGS_FILE"; then
            status_info="${status_info}   Config: $GLOBAL_SETTINGS_FILE (new format)\n"
        else
            status_info="${status_info}   Config: $GLOBAL_HOOKS_FILE (legacy)\n"
        fi
    else
        status_info="${status_info}${MUTE} Global notifications: ${DIM}DISABLED${RESET}\n"
    fi
    
    # Project status
    local project_name=$(get_project_name)
    local project_root=$(get_project_root)
    status_info="${status_info}\n${FOLDER} Project: $project_name\n"
    status_info="${status_info}   Location: $project_root\n"
    
    if is_enabled_project; then
        status_info="${status_info}${BELL} Project notifications: ${GREEN}ENABLED${RESET}\n"
        # Check which format is being used
        if is_enabled_project_settings; then
            status_info="${status_info}   Config: $project_root/.claude/settings.json (new format)\n"
        else
            status_info="${status_info}   Config: $project_root/.claude/hooks.json (legacy)\n"
        fi
    else
        status_info="${status_info}${MUTE} Project notifications: ${DIM}DISABLED${RESET}\n"
    fi
    
    # Terminal notifier status
    if detect_terminal_notifier &> /dev/null; then
        status_info="${status_info}\n${CHECK_MARK} terminal-notifier: ${GREEN}INSTALLED${RESET}\n"
    else
        status_info="${status_info}\n${WARNING} terminal-notifier: ${YELLOW}NOT INSTALLED${RESET}\n"
        status_info="${status_info}   Install with: ${CYAN}brew install terminal-notifier${RESET}\n"
    fi
    
    echo -e "$status_info"
}

# Enable hooks in settings.json (new format)
enable_hooks_in_settings() {
    local notify_script=$(get_notify_script)
    local notify_matcher=$(get_notify_matcher)

    # Ensure .claude directory exists
    mkdir -p "$(dirname "$GLOBAL_SETTINGS_FILE")"

    # Add hooks using jq (preferred) or python (fallback)
    if has_jq; then
        safe_jq_update "$GLOBAL_SETTINGS_FILE" '.hooks = {
            "Notification": [{
                "matcher": $matcher,
                "hooks": [{
                    "type": "command",
                    "command": ($script + " notification claude")
                }]
            }],
            "Stop": [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": ($script + " stop claude")
                }]
            }]
        }' --arg script "$notify_script" --arg matcher "$notify_matcher"
    elif has_python3; then
        # Use Python as fallback - pass JSON via temp file to avoid shell escaping issues
        local settings="{}"
        if [[ -f "$GLOBAL_SETTINGS_FILE" ]]; then
            settings=$(cat "$GLOBAL_SETTINGS_FILE")
        fi

        local tmp_json
        tmp_json=$(mktemp) || { echo "Error: Failed to create temp file" >&2; return 1; }

        # Write settings to temp file, then have Python read and clean it up
        printf '%s\n' "$settings" > "$tmp_json"

        python3 - "$GLOBAL_SETTINGS_FILE" "$notify_script" "$notify_matcher" "$tmp_json" << 'PYTHON'
import sys
import json
import tempfile
import os

file_path = sys.argv[1]
script = sys.argv[2]
matcher = sys.argv[3]
json_file = sys.argv[4]

try:
    with open(json_file, 'r') as f:
        settings = json.load(f)
finally:
    # Always clean up temp file
    try:
        os.unlink(json_file)
    except OSError:
        pass

settings['hooks'] = {
    'Notification': [{
        'matcher': matcher,
        'hooks': [{'type': 'command', 'command': f'{script} notification claude'}]
    }],
    'Stop': [{
        'matcher': '',
        'hooks': [{'type': 'command', 'command': f'{script} stop claude'}]
    }]
}

# Atomic write: write to temp file, then rename
dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)

fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix='.tmp.')
try:
    with os.fdopen(fd, 'w') as f:
        f.write(content)
        f.write('\n')
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
    else
        # No jq or python - abort to avoid data loss
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Disable hooks in settings.json (new format)
disable_hooks_in_settings() {
    if [[ ! -f "$GLOBAL_SETTINGS_FILE" ]]; then
        return 0
    fi

    # Remove hooks using jq (preferred) or python (fallback)
    if has_jq; then
        local settings new_settings
        settings=$(cat "$GLOBAL_SETTINGS_FILE")

        # Apply jq filter with error checking
        if ! new_settings=$(echo "$settings" | jq 'del(.hooks)' 2>/dev/null); then
            echo "Error: Failed to parse configuration JSON" >&2
            echo "File unchanged: $GLOBAL_SETTINGS_FILE" >&2
            return 1
        fi

        # Only write if there's actual content left (not just {})
        if [[ "$new_settings" != "{}" ]]; then
            atomic_write "$GLOBAL_SETTINGS_FILE" "$new_settings"
        else
            # File would be empty, just remove it
            rm -f "$GLOBAL_SETTINGS_FILE"
        fi
    elif has_python3; then
        python3 - "$GLOBAL_SETTINGS_FILE" << 'PYTHON'
import sys
import json
import os
import tempfile

file_path = sys.argv[1]
with open(file_path, 'r') as f:
    settings = json.load(f)

if 'hooks' in settings:
    del settings['hooks']

if settings:
    # Atomic write: write to temp file, then rename
    dir_path = os.path.dirname(file_path)
    content = json.dumps(settings, indent=2)

    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix='.tmp.')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(content)
            f.write('\n')
        os.replace(tmp_path, file_path)
    except Exception:
        os.unlink(tmp_path)
        raise
else:
    os.remove(file_path)
PYTHON
    else
        # No jq or python - abort to avoid data loss
        echo "Error: jq or python3 required to safely disable hooks" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Enable hooks in project settings.json
enable_project_hooks_in_settings() {
    local project_root="${1:-$(get_project_root)}"
    local project_name="${2:-$(get_project_name)}"
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    local notify_script=$(get_notify_script)
    local notify_matcher=$(get_notify_matcher)

    # Ensure .claude directory exists
    mkdir -p "$project_root/.claude"

    # Read existing settings or create new
    local settings="{}"
    if [[ -f "$project_settings" ]]; then
        settings=$(cat "$project_settings")
    fi

    # Add hooks using jq (preferred) or python (fallback)
    if has_jq; then
        # Pre-quote script and name for safe shell execution
        local quoted_script=$(shell_quote "$notify_script")
        local quoted_name=$(shell_quote "$project_name")

        safe_jq_update "$project_settings" '.hooks = {
            "Notification": [{
                "matcher": $matcher,
                "hooks": [{
                    "type": "command",
                    "command": ($qscript + " notification claude " + $qname)
                }]
            }],
            "Stop": [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": ($qscript + " stop claude " + $qname)
                }]
            }]
        }' --arg matcher "$notify_matcher" --arg qscript "$quoted_script" --arg qname "$quoted_name"
    elif has_python3; then
        # Use Python fallback - pass JSON via temp file to avoid shell escaping issues
        local tmp_json
        tmp_json=$(mktemp) || { echo "Error: Failed to create temp file" >&2; return 1; }

        printf '%s\n' "$settings" > "$tmp_json"

        python3 - "$project_settings" "$notify_script" "$notify_matcher" "$project_name" "$tmp_json" << 'PYTHON'
import sys
import json
import tempfile
import os
import shlex

file_path = sys.argv[1]
script = sys.argv[2]
matcher = sys.argv[3]
name = sys.argv[4]
json_file = sys.argv[5]

try:
    with open(json_file, 'r') as f:
        settings = json.load(f)
finally:
    try:
        os.unlink(json_file)
    except OSError:
        pass

# Shell-quote script and name for safe command execution
qscript = shlex.quote(script)
qname = shlex.quote(name)

settings['hooks'] = {
    'Notification': [{
        'matcher': matcher,
        'hooks': [{'type': 'command', 'command': f'{qscript} notification claude {qname}'}]
    }],
    'Stop': [{
        'matcher': '',
        'hooks': [{'type': 'command', 'command': f'{qscript} stop claude {qname}'}]
    }]
}

# Atomic write: write to temp file, then rename
dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)

fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix='.tmp.')
try:
    with os.fdopen(fd, 'w') as f:
        f.write(content)
        f.write('\n')
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
    else
        # No jq or python - abort to avoid data loss
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Check if project has settings.json with code-notify hooks
is_enabled_project_settings() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    has_claude_notify_hooks "$project_settings"
}

# ============================================
# Codex Configuration
# ============================================

# Check if Codex notifications are enabled
is_codex_enabled() {
    toml_has_top_level_key "$CODEX_CONFIG_FILE" "notify"
}

# Enable Codex notifications
enable_codex_hooks() {
    local notify_script=$(get_notify_script)
    local escaped_notify_script
    local notify_line

    # Ensure .codex directory exists
    mkdir -p "$CODEX_HOME"

    escaped_notify_script=$(toml_escape_string "$notify_script")
    notify_line="notify = [\"$escaped_notify_script\", \"codex\"]"

    # Check if config.toml exists
    if [[ -f "$CODEX_CONFIG_FILE" ]]; then
        # Backup existing config
        backup_config "$CODEX_CONFIG_FILE"

        upsert_codex_notify_config "$CODEX_CONFIG_FILE" "$notify_line"
    else
        # Create new config.toml
        cat > "$CODEX_CONFIG_FILE" << EOF
# Codex CLI Configuration
# https://developers.openai.com/codex/config-reference/

# Code-Notify: Desktop notifications
notify = ["$escaped_notify_script", "codex"]
EOF
    fi
}

# Disable Codex notifications
disable_codex_hooks() {
    if [[ ! -f "$CODEX_CONFIG_FILE" ]]; then
        return 0
    fi

    # Backup before modifying
    backup_config "$CODEX_CONFIG_FILE"

    # Remove notify line and comment (BSD sed compatible)
    sed -i '' '/^# Code-Notify/d' "$CODEX_CONFIG_FILE" 2>/dev/null || sed -i '/^# Code-Notify/d' "$CODEX_CONFIG_FILE"
    sed -i '' '/^notify.*=/d' "$CODEX_CONFIG_FILE" 2>/dev/null || sed -i '/^notify.*=/d' "$CODEX_CONFIG_FILE"
}

# ============================================
# Gemini CLI Configuration
# ============================================

# Check if Gemini CLI notifications are enabled
is_gemini_enabled() {
    if [[ ! -f "$GEMINI_SETTINGS_FILE" ]]; then
        return 1
    fi
    # Check for our hooks in Gemini settings
    if has_jq; then
        jq -e '.hooks.AfterAgent != null or .hooks.Notification != null' "$GEMINI_SETTINGS_FILE" &>/dev/null
    else
        grep -qE '"(AfterAgent|Notification)"' "$GEMINI_SETTINGS_FILE" 2>/dev/null
    fi
}

# Enable Gemini CLI notifications
enable_gemini_hooks() {
    local notify_script=$(get_notify_script)

    # Ensure .gemini directory exists
    mkdir -p "$GEMINI_HOME"

    # Backup existing config
    if [[ -f "$GEMINI_SETTINGS_FILE" ]]; then
        backup_config "$GEMINI_SETTINGS_FILE"
    fi

    if has_jq; then
        # Use safe_jq_update for error checking
        safe_jq_update "$GEMINI_SETTINGS_FILE" '
            .tools.enableHooks = true |
            .hooks.enabled = true |
            .hooks.Notification = [{
                "matcher": "",
                "hooks": [{
                    "name": "code-notify-notification",
                    "type": "command",
                    "command": ($script + " notification gemini"),
                    "description": "Desktop notification when input needed"
                }]
            }] |
            .hooks.AfterAgent = [{
                "matcher": "",
                "hooks": [{
                    "name": "code-notify-complete",
                    "type": "command",
                    "command": ($script + " stop gemini"),
                    "description": "Desktop notification when task complete"
                }]
            }]
        ' --arg script "$notify_script"
    elif has_python3; then
        # Use Python fallback - pass JSON via temp file to avoid shell escaping issues
        local settings="{}"
        if [[ -f "$GEMINI_SETTINGS_FILE" ]]; then
            settings=$(cat "$GEMINI_SETTINGS_FILE")
        fi

        local tmp_json
        tmp_json=$(mktemp) || { echo "Error: Failed to create temp file" >&2; return 1; }

        printf '%s\n' "$settings" > "$tmp_json"

        python3 - "$GEMINI_SETTINGS_FILE" "$notify_script" "$tmp_json" << 'PYTHON'
import sys
import json
import tempfile
import os

file_path = sys.argv[1]
script = sys.argv[2]
json_file = sys.argv[3]

try:
    with open(json_file, 'r') as f:
        settings = json.load(f)
finally:
    # Always clean up temp file
    try:
        os.unlink(json_file)
    except OSError:
        pass

settings.setdefault('tools', {})['enableHooks'] = True
settings.setdefault('hooks', {})['enabled'] = True
settings['hooks']['Notification'] = [{
    'matcher': '',
    'hooks': [{
        'name': 'code-notify-notification',
        'type': 'command',
        'command': f'{script} notification gemini',
        'description': 'Desktop notification when input needed'
    }]
}]
settings['hooks']['AfterAgent'] = [{
    'matcher': '',
    'hooks': [{
        'name': 'code-notify-complete',
        'type': 'command',
        'command': f'{script} stop gemini',
        'description': 'Desktop notification when task complete'
    }]
}]

# Atomic write: write to temp file, then rename
dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)

fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix='.tmp.')
try:
    with os.fdopen(fd, 'w') as f:
        f.write(content)
        f.write('\n')
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
    else
        # No jq or python - abort to avoid data loss
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Disable Gemini CLI notifications
disable_gemini_hooks() {
    if [[ ! -f "$GEMINI_SETTINGS_FILE" ]]; then
        return 0
    fi

    backup_config "$GEMINI_SETTINGS_FILE"

    if has_jq; then
        local settings new_settings
        settings=$(cat "$GEMINI_SETTINGS_FILE")

        # Remove code-notify specific hooks with error checking
        if ! new_settings=$(echo "$settings" | jq 'del(.hooks.Notification) | del(.hooks.AfterAgent) | del(.hooks.enabled)' 2>/dev/null); then
            echo "Error: Failed to parse configuration JSON" >&2
            echo "File unchanged: $GEMINI_SETTINGS_FILE" >&2
            return 1
        fi

        # If hooks object is now empty, remove it entirely
        if ! new_settings=$(echo "$new_settings" | jq 'if .hooks == {} then del(.hooks) else . end' 2>/dev/null); then
            echo "Error: Failed to process configuration JSON" >&2
            echo "File unchanged: $GEMINI_SETTINGS_FILE" >&2
            return 1
        fi

        if [[ "$new_settings" != "{}" ]]; then
            atomic_write "$GEMINI_SETTINGS_FILE" "$new_settings"
        else
            rm -f "$GEMINI_SETTINGS_FILE"
        fi
    elif has_python3; then
        python3 - "$GEMINI_SETTINGS_FILE" << 'PYTHON'
import sys
import json
import os
import tempfile

file_path = sys.argv[1]
with open(file_path, 'r') as f:
    settings = json.load(f)

if 'hooks' in settings:
    settings['hooks'].pop('Notification', None)
    settings['hooks'].pop('AfterAgent', None)
    settings['hooks'].pop('enabled', None)
    if not settings['hooks']:
        del settings['hooks']

if settings:
    # Atomic write: write to temp file, then rename
    dir_path = os.path.dirname(file_path)
    content = json.dumps(settings, indent=2)

    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix='.tmp.')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(content)
            f.write('\n')
        os.replace(tmp_path, file_path)
    except Exception:
        os.unlink(tmp_path)
        raise
else:
    os.remove(file_path)
PYTHON
    else
        # No jq or python - abort to avoid data loss
        echo "Error: jq or python3 required to safely disable hooks" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# ============================================
# Multi-tool helpers
# ============================================

# Enable notifications for a specific tool
enable_tool() {
    local tool="$1"

    case "$tool" in
        "claude")
            enable_hooks_in_settings
            ;;
        "codex")
            enable_codex_hooks
            ;;
        "gemini")
            enable_gemini_hooks
            ;;
        *)
            return 1
            ;;
    esac
}

# Disable notifications for a specific tool
disable_tool() {
    local tool="$1"

    case "$tool" in
        "claude")
            disable_hooks_in_settings
            ;;
        "codex")
            disable_codex_hooks
            ;;
        "gemini")
            disable_gemini_hooks
            ;;
        *)
            return 1
            ;;
    esac
}

# Check if a specific tool has notifications enabled
is_tool_enabled() {
    local tool="$1"

    case "$tool" in
        "claude")
            is_enabled_globally
            ;;
        "codex")
            is_codex_enabled
            ;;
        "gemini")
            is_gemini_enabled
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================
# Notification Types Management
# ============================================

# Get current notification types (returns pipe-separated list)
get_notify_types() {
    if [[ -f "$NOTIFY_TYPES_FILE" ]]; then
        cat "$NOTIFY_TYPES_FILE"
    else
        echo "$DEFAULT_NOTIFY_TYPE"
    fi
}

# Set notification types
set_notify_types() {
    local types="$1"
    mkdir -p "$(dirname "$NOTIFY_TYPES_FILE")"
    echo "$types" > "$NOTIFY_TYPES_FILE"
}

# Add a notification type
add_notify_type() {
    local type="$1"
    local current=$(get_notify_types)

    if [[ "$current" == *"$type"* ]]; then
        return 0  # Already exists
    fi

    if [[ -z "$current" ]]; then
        set_notify_types "$type"
    else
        set_notify_types "$current|$type"
    fi
}

# Remove a notification type
remove_notify_type() {
    local type="$1"
    local current=$(get_notify_types)

    # Remove the type (handle edge cases)
    local new_types=$(echo "$current" | sed "s/|$type//g; s/$type|//g; s/^$type$//g")

    if [[ -z "$new_types" ]]; then
        new_types="$DEFAULT_NOTIFY_TYPE"
    fi

    set_notify_types "$new_types"
}

# Check if a notification type is enabled
is_notify_type_enabled() {
    local type="$1"
    local current=$(get_notify_types)
    [[ "$current" == *"$type"* ]]
}

# Reset to default notification type
reset_notify_types() {
    set_notify_types "$DEFAULT_NOTIFY_TYPE"
}

# Get matcher pattern for current notification types
get_notify_matcher() {
    get_notify_types
}
