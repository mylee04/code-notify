#!/bin/bash

# Core notification functionality for Code-Notify
# Supports: Claude Code, Codex, Gemini CLI

# Get arguments:
#   Claude/Gemini: notify.sh <hook_type> <tool_name> [project_name]
#   Codex:         notify.sh codex <payload_json>
RAW_ARG1="${1:-}"
RAW_ARG2="${2:-}"
RAW_ARG3="${3:-}"

# Source shared utilities
NOTIFIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$NOTIFIER_DIR/../utils/detect.sh"
source "$NOTIFIER_DIR/../utils/voice.sh"
source "$NOTIFIER_DIR/../utils/sound.sh"
source "$NOTIFIER_DIR/../utils/click-through-store.sh"
source "$NOTIFIER_DIR/../utils/click-through-runtime.sh"
source "$NOTIFIER_DIR/../utils/click-through-resolver.sh"

has_jq() {
    command -v jq >/dev/null 2>&1
}

has_python3() {
    command -v python3 >/dev/null 2>&1
}

json_extract_string() {
    local json="$1"
    local key="$2"

    if [[ -z "$json" ]]; then
        return 0
    fi

    if has_jq; then
        printf '%s' "$json" | jq -r --arg key "$key" '(.[$key] // "") | if type == "string" then . else "" end' 2>/dev/null
        return 0
    fi

    if has_python3; then
        printf '%s' "$json" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    value = json.load(sys.stdin).get(key, "")
except Exception:
    value = ""
print(value if isinstance(value, str) else "", end="")
' "$key" 2>/dev/null
        return 0
    fi

    case "$key" in
        "type")
            printf '%s' "$json" | sed -nE 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "cwd")
            printf '%s' "$json" | sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
    esac
}

get_codex_hook_type() {
    local payload_type
    payload_type=$(json_extract_string "$HOOK_DATA" "type" | tr '[:upper:]' '[:lower:]')

    case "$payload_type" in
        "agent-turn-complete")
            printf '%s\n' "stop"
            return 0
            ;;
        *"request_permissions"*|*"permission"*|*"approval"*|*"elicitation"*|*"prompt"*)
            printf '%s\n' "notification"
            return 0
            ;;
        *"error"*|*"failed"*)
            printf '%s\n' "error"
            return 0
            ;;
    esac

    if [[ "$HOOK_DATA" == *"last-assistant-message"* ]]; then
        printf '%s\n' "stop"
    elif [[ "$HOOK_DATA" == *"request_permissions"* ]] || [[ "$HOOK_DATA" == *"approval"* ]] || [[ "$HOOK_DATA" == *"permission"* ]]; then
        printf '%s\n' "notification"
    else
        printf '%s\n' "stop"
    fi
}

get_codex_project_name() {
    local payload_cwd
    payload_cwd=$(json_extract_string "$HOOK_DATA" "cwd")

    if [[ -n "$payload_cwd" ]]; then
        basename "$payload_cwd"
    else
        basename "$PWD"
    fi
}

HOOK_DATA=""
if [[ "$RAW_ARG1" == "codex" ]]; then
    TOOL_NAME="codex"
    HOOK_DATA="$RAW_ARG2"
    HOOK_TYPE=$(get_codex_hook_type)
    PROJECT_NAME="${RAW_ARG3:-$(get_codex_project_name)}"
else
    HOOK_TYPE=${CLAUDE_HOOK_TYPE:-$RAW_ARG1}
    TOOL_NAME="${RAW_ARG2:-""}"
    PROJECT_NAME="${RAW_ARG3:-$(basename "$PWD")}"

    # Read hook data from stdin (Claude Code passes JSON with hook context)
    if [[ ! -t 0 ]]; then
        HOOK_DATA=$(cat 2>/dev/null || true)
    fi
fi

# Get display name for tool
get_tool_display_name() {
    local tool="$1"
    case "$tool" in
        "claude") echo "Claude" ;;
        "codex") echo "Codex" ;;
        "gemini") echo "Gemini" ;;
        *) echo "AI" ;;
    esac
}

TOOL_DISPLAY=$(get_tool_display_name "$TOOL_NAME")

# Rate limiting for stop notifications (prevents spam from parallel sub-agents)
RATE_LIMIT_DIR="$HOME/.claude/notifications"
STOP_RATE_LIMIT_SECONDS="${CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS:-10}"
NOTIFICATION_RATE_LIMIT_SECONDS="${CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS:-180}"

sanitize_rate_limit_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

get_rate_limit_file() {
    local key
    key=$(sanitize_rate_limit_key "$1")
    printf '%s/%s\n' "$RATE_LIMIT_DIR" "$key"
}

get_notification_subtype() {
    if [[ "$HOOK_DATA" == *"idle_prompt"* ]]; then
        printf '%s\n' "idle_prompt"
        return 0
    fi

    if [[ "$HOOK_DATA" == *"permission_prompt"* ]] || [[ "$HOOK_DATA" == *"request_permissions"* ]] || [[ "$HOOK_DATA" == *"sandbox_approval"* ]]; then
        printf '%s\n' "permission_prompt"
        return 0
    fi

    if [[ "$HOOK_DATA" == *"auth_success"* ]]; then
        printf '%s\n' "auth_success"
        return 0
    fi

    if [[ "$HOOK_DATA" == *"elicitation_dialog"* ]] || [[ "$HOOK_DATA" == *"mcp_elicitations"* ]]; then
        printf '%s\n' "elicitation_dialog"
        return 0
    fi

    printf '%s\n' "notification"
}

get_notification_rate_limit_key() {
    local subtype
    subtype=$(get_notification_subtype)
    printf '%s\n' "last_notification_${TOOL_NAME}_${PROJECT_NAME}_${subtype}"
}

is_rate_limited() {
    local rate_limit_key="$1"
    local rate_limit_seconds="$2"
    local lock_file
    lock_file=$(get_rate_limit_file "$rate_limit_key")

    if [[ ! -f "$lock_file" ]]; then
        return 1  # No previous notification, not rate limited
    fi

    local last_time
    last_time=$(cat "$lock_file" 2>/dev/null || echo "0")
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - last_time))

    if [[ $elapsed -lt $rate_limit_seconds ]]; then
        return 0  # Rate limited
    fi

    return 1  # Not rate limited
}

update_rate_limit() {
    local rate_limit_key="$1"
    local lock_file
    lock_file=$(get_rate_limit_file "$rate_limit_key")
    mkdir -p "$RATE_LIMIT_DIR"
    date +%s > "$lock_file"
}

is_project_scoped_notification() {
    if [[ "${CODE_NOTIFY_SCOPE:-}" == "project" ]]; then
        return 0
    fi

    if [[ "$RAW_ARG1" != "codex" ]] && [[ -n "$RAW_ARG3" ]]; then
        return 0
    fi

    return 1
}

# Function to check if notification should be suppressed
should_suppress_notification() {
    # Check kill switch first - instant disable without restart
    if [[ -f "$HOME/.claude/notifications/disabled" ]] && ! is_project_scoped_notification; then
        return 0  # Suppress notification
    fi

    # Skip suppression checks for test notifications
    if [[ "$HOOK_TYPE" == "test" ]]; then
        return 1
    fi

    # Rate limit stop notifications to prevent spam from parallel sub-agents
    if [[ "$HOOK_TYPE" == "stop" ]]; then
        if is_rate_limited "last_stop_notification" "$STOP_RATE_LIMIT_SECONDS"; then
            return 0  # Suppress - too soon since last notification
        fi
    fi

    # Suppress repeated state-style notifications such as idle_prompt.
    if [[ "$HOOK_TYPE" == "notification" ]]; then
        if is_rate_limited "$(get_notification_rate_limit_key)" "$NOTIFICATION_RATE_LIMIT_SECONDS"; then
            return 0
        fi
    fi

    # For Stop hooks: Check if stop_hook_active is true
    if [[ "$HOOK_TYPE" == "stop" ]] && [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"stop_hook_active":\s*true' 2>/dev/null; then
            return 0
        fi
    fi

    # Check for auto-accept indicator
    if [[ "${CLAUDE_AUTO_ACCEPT:-}" == "true" ]]; then
        return 0
    fi

    if [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"autoAccepted":\s*true' 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Check if notification should be suppressed
if [[ "$HOOK_TYPE" == "stop" ]] || [[ "$HOOK_TYPE" == "notification" ]]; then
    if should_suppress_notification; then
        exit 0
    fi
fi

# Update rate limit timestamp for stop notifications
if [[ "$HOOK_TYPE" == "stop" ]]; then
    update_rate_limit "last_stop_notification"
elif [[ "$HOOK_TYPE" == "notification" ]]; then
    update_rate_limit "$(get_notification_rate_limit_key)"
fi

# Set notification parameters based on hook type and tool
case "$HOOK_TYPE" in
    "stop")
        TITLE="$TOOL_DISPLAY ✅"
        SUBTITLE="Task Complete"
        MESSAGE="$TOOL_DISPLAY completed the task"
        VOICE_MESSAGE="$TOOL_DISPLAY completed the task"
        SOUND="Glass"
        ;;
    "notification")
        TITLE="$TOOL_DISPLAY 🔔"
        SUBTITLE="Input Required"
        MESSAGE="$TOOL_DISPLAY needs your input"
        VOICE_MESSAGE="$TOOL_DISPLAY needs your input"
        SOUND="Ping"
        ;;
    "error"|"failed")
        TITLE="$TOOL_DISPLAY ❌"
        SUBTITLE="Error"
        MESSAGE="An error occurred in $TOOL_DISPLAY"
        VOICE_MESSAGE="An error occurred in $TOOL_DISPLAY"
        SOUND="Basso"
        ;;
    "test")
        TITLE="Code-Notify Test ✅"
        SUBTITLE="$PROJECT_NAME"
        MESSAGE="Notifications are working!"
        VOICE_MESSAGE="Notifications are working"
        SOUND="Glass"
        ;;
    "PreToolUse")
        # Silent for PreToolUse - just log, no notification
        exit 0
        ;;
    *)
        TITLE="$TOOL_DISPLAY 📢"
        SUBTITLE="Status Update"
        MESSAGE="$TOOL_DISPLAY: $HOOK_TYPE"
        VOICE_MESSAGE="$TOOL_DISPLAY status update"
        SOUND="Pop"
        ;;
esac

# Add project name to subtitle if available
if [[ -n "$PROJECT_NAME" ]] && [[ "$HOOK_TYPE" != "test" ]]; then
    SUBTITLE="$SUBTITLE - $PROJECT_NAME"
fi

# Get terminal bundle ID for macOS activation
get_terminal_bundle_id() {
    click_through_resolve_activation_bundle_id
}

# Function to send notification on macOS
send_macos_notification() {
    local bundle_id
    bundle_id=$(get_terminal_bundle_id)

    if command -v terminal-notifier &> /dev/null; then
        # Keep desktop notifications silent and let play_sound() own audio playback.
        # That avoids double audio and preserves custom sound files.
        terminal-notifier \
            -title "$TITLE" \
            -subtitle "$SUBTITLE" \
            -message "$MESSAGE" \
            -group "code-notify-$TOOL_NAME-$PROJECT_NAME" \
            -activate "$bundle_id" \
            2>/dev/null
    else
        # osascript doesn't support click-to-activate, but we can use a workaround.
        # Keep this silent too so custom/default sound playback stays single-sourced.
        osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" subtitle \"$SUBTITLE\"" 2>/dev/null
    fi
}

# Function to send notification on Linux
send_linux_notification() {
    if command -v notify-send &> /dev/null; then
        notify-send "$TITLE" "$MESSAGE" \
            --urgency=normal \
            --app-name="Code-Notify" \
            --icon=dialog-information \
            2>/dev/null
    elif command -v zenity &> /dev/null; then
        zenity --notification \
            --text="$TITLE\n$MESSAGE" \
            2>/dev/null
    else
        echo "[$TITLE] $MESSAGE" | wall 2>/dev/null
    fi
}

# Strip non-ASCII characters before sending toast text to wsl-notify-send.exe.
sanitize_wsl_text() {
    printf '%s' "$1" | LC_ALL=C sed 's/[^\x20-\x7E]//g; s/  */ /g; s/^ *//; s/ *$//'
}

# Function to send notification on Windows
send_windows_notification() {
    if command -v powershell &> /dev/null; then
        powershell -Command "
            if (Get-Module -ListAvailable -Name BurntToast) {
                New-BurntToastNotification -Text '$TITLE', '$MESSAGE'
            } else {
                Add-Type -AssemblyName System.Windows.Forms
                \$notification = New-Object System.Windows.Forms.NotifyIcon
                \$notification.Icon = [System.Drawing.SystemIcons]::Information
                \$notification.BalloonTipIcon = 'Info'
                \$notification.BalloonTipTitle = '$TITLE'
                \$notification.BalloonTipText = '$MESSAGE'
                \$notification.Visible = \$true
                \$notification.ShowBalloonTip(10000)
            }
        " 2>/dev/null
    elif command -v msg &> /dev/null; then
        msg "%USERNAME%" "$TITLE: $MESSAGE" 2>/dev/null
    fi
}

# Check if voice is enabled for this tool
should_speak() {
    # Check tool-specific voice setting first
    if [[ -n "$TOOL_NAME" ]]; then
        local tool_voice_file="$HOME/.claude/notifications/voice-$TOOL_NAME"
        if [[ -f "$tool_voice_file" ]]; then
            return 0
        fi
    fi

    # Fall back to global voice setting
    local global_voice_file="$HOME/.claude/notifications/voice-enabled"
    if [[ -f "$global_voice_file" ]]; then
        return 0
    fi

    return 1
}

# Get voice setting (tool-specific or global)
get_voice_setting() {
    # Check tool-specific voice first
    if [[ -n "$TOOL_NAME" ]]; then
        local tool_voice_file="$HOME/.claude/notifications/voice-$TOOL_NAME"
        if [[ -f "$tool_voice_file" ]]; then
            cat "$tool_voice_file"
            return
        fi
    fi

    # Fall back to global
    get_voice "global" 2>/dev/null || echo ""
}

# Check if sound should play
should_play_sound() {
    is_sound_enabled
}

# Send notification based on OS
OS=$(detect_os)
case "$OS" in
    macos)
        send_macos_notification
        # Voice notification if enabled
        if should_speak; then
            VOICE=$(get_voice_setting)
            if [[ -n "$VOICE" ]]; then
                say -v "$VOICE" "$VOICE_MESSAGE"
            fi
        fi
        # Sound notification if enabled (separate from voice)
        if should_play_sound; then
            play_sound
        fi
        ;;
    linux)
        send_linux_notification
        # Sound notification if enabled
        if should_play_sound; then
            play_sound
        fi
        ;;
    wsl)
        # Send Windows toast notification via wsl-notify-send.exe
        # Windows requires toast notifications to use an AppUserModelID registered via a Start Menu
        # shortcut. Without a registered appId, toasts may not appear or only show in Action Center.
        # We borrow the terminal's appId since it's already registered and has banner permissions.
        if command -v wsl-notify-send.exe &> /dev/null; then
            WSL_APP_ID=""
            # Detect terminal app ID from environment
            if [[ "${WT_SESSION:-}" != "" ]]; then
                # Running inside Windows Terminal
                WSL_APP_ID="Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
            fi
            # Strip non-ASCII (emojis corrupt the XML toast template inside wsl-notify-send.exe)
            # wsl-notify-send.exe only accepts ONE positional arg; two args prints usage and exits
            WSL_TITLE=$(sanitize_wsl_text "$TITLE")
            WSL_MESSAGE=$(sanitize_wsl_text "$MESSAGE")
            # Add project name and branch to body
            WSL_BRANCH=$(sanitize_wsl_text "$(git -C "$PWD" branch --show-current 2>/dev/null || true)")
            WSL_PROJECT=$(sanitize_wsl_text "$PROJECT_NAME")
            if [[ -n "$WSL_BRANCH" ]]; then
                WSL_PROJECT="$WSL_PROJECT ($WSL_BRANCH)"
            fi
            WSL_NOTIFY_ARGS=(--appId "${WSL_APP_ID:-wsl-notify-send}" -c "$WSL_TITLE")
            WSL_BODY=$(printf '%s\n%s' "$WSL_PROJECT" "$WSL_MESSAGE")
            wsl-notify-send.exe "${WSL_NOTIFY_ARGS[@]}" "$WSL_BODY" 2>/dev/null
        else
            # Fallback to notify-send (only works if WSLg is active)
            send_linux_notification
        fi
        # Sound notification if enabled
        if should_play_sound; then
            play_sound
        fi
        ;;
    windows)
        send_windows_notification
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

# Log the notification
LOG_DIR="$HOME/.claude/logs"
if [[ -d "$LOG_DIR" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$TOOL_NAME] [$PROJECT_NAME] $MESSAGE" >> "$LOG_DIR/notifications.log"
fi

exit 0
