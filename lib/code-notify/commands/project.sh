#!/bin/bash

# Project-specific command handlers for Code-Notify

# Source voice utilities
PROJECT_CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_CMD_DIR/../utils/voice.sh"

# Handle project commands
handle_project_command() {
    local command="${1:-status}"
    shift
    
    case "$command" in
        "on")
            enable_notifications_project "$@"
            ;;
        "off")
            disable_notifications_project "$@"
            ;;
        "status")
            show_project_status "$@"
            ;;
        "init")
            init_project_interactive "$@"
            ;;
        "voice")
            shift
            handle_project_voice_command "$@"
            ;;
        *)
            error "Unknown project command: $command"
            echo "Valid commands: on, off, status, init, voice"
            exit 1
            ;;
    esac
}

get_claude_trust_file() {
    echo "${CODE_NOTIFY_CLAUDE_TRUST_FILE:-$HOME/.claude.json}"
}

is_claude_project_trusted() {
    local project_root="${1:-$(get_project_root 2>/dev/null || echo "$PWD")}"
    local trust_file
    trust_file="$(get_claude_trust_file)"

    if [[ ! -f "$trust_file" ]]; then
        return 2
    fi

    if has_jq; then
        jq empty "$trust_file" >/dev/null 2>&1 || return 2
        jq -e --arg project "$project_root" '.projects[$project].hasTrustDialogAccepted == true' "$trust_file" >/dev/null 2>&1
        return $?
    fi

    if has_python3; then
        python3 - "$trust_file" "$project_root" <<'PY'
import json
import sys

trust_file = sys.argv[1]
project_root = sys.argv[2]

try:
    with open(trust_file, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(2)

projects = data.get("projects")
if not isinstance(projects, dict):
    raise SystemExit(2)

entry = projects.get(project_root)
if isinstance(entry, dict) and entry.get("hasTrustDialogAccepted") is True:
    raise SystemExit(0)

raise SystemExit(1)
PY
        return $?
    fi

    return 2
}

warn_if_claude_project_untrusted() {
    local project_root="${1:-$(get_project_root 2>/dev/null || echo "$PWD")}"
    local trust_status

    if is_claude_project_trusted "$project_root"; then
        trust_status=0
    else
        trust_status=$?
    fi

    if [[ $trust_status -eq 0 ]]; then
        return 0
    fi

    if [[ $trust_status -ne 1 ]]; then
        return 0
    fi

    echo ""
    warning "Claude project trust does not appear to be accepted for this project yet"
    info "Project hooks are configured, but Claude may ignore project settings until this project is trusted"
    info "Open Claude Code in ${CYAN}$project_root${RESET} and accept the trust prompt if it appears"
    return 0
}

# Enable notifications for current project
enable_notifications_project() {
    local project_root=$(get_project_root)
    local project_name=$(get_project_name)
    local project_hooks_dir="$project_root/.claude"
    local project_settings_file="$project_hooks_dir/settings.json"
    local project_hooks_file="$project_hooks_dir/hooks.json"  # Legacy
    
    header "${ROCKET} Enabling Notifications for Project: $project_name"
    echo ""
    info "Project location: $project_root"
    
    # Check if already enabled (either format)
    if is_enabled_project_settings || [[ -f "$project_hooks_file" ]]; then
        warning "Project notifications are already enabled"
        if [[ -f "$project_settings_file" ]]; then
            info "Config: $project_settings_file (new format)"
        else
            info "Config: $project_hooks_file (legacy)"
        fi
        return 0
    fi
    
    # Create .claude directory if needed
    if [[ ! -d "$project_hooks_dir" ]]; then
        info "Creating project configuration directory..."
        mkdir -p "$project_hooks_dir"
    fi
    
    # Create project-specific configuration using new format
    info "Creating project-specific configuration (settings.json)..."
    enable_project_hooks_in_settings "$project_root" "$project_name"
    
    success "Project notifications ENABLED"
    info "Config created at: $project_settings_file"
    warn_if_claude_project_untrusted "$project_root"
    
    # Send test notification
    echo ""
    info "Sending test notification..."
    local notify_script=$(get_notify_script)
    if [[ -f "$notify_script" ]]; then
        "$notify_script" "test" "completed" "$project_name"
    else
        # Fallback notification
        if command -v terminal-notifier &> /dev/null; then
            terminal-notifier \
                -title "Code-Notify Test ${CHECK_MARK}" \
                -message "Project notifications enabled for $project_name" \
                -sound "Glass"
        else
            osascript -e "display notification \"Project notifications enabled for $project_name\" with title \"Code-Notify Test\"" 2>/dev/null || true
        fi
    fi
    
    echo ""
    dim "Note: Project settings override global settings, including the global mute file"
}

# Disable notifications for current project
disable_notifications_project() {
    local project_root=$(get_project_root)
    local project_name=$(get_project_name)
    local project_settings_file="$project_root/.claude/settings.json"
    local project_hooks_file="$project_root/.claude/hooks.json"
    local removed_any=0
    
    header "${MUTE} Disabling Notifications for Project: $project_name"
    echo ""
    
    if [[ ! -f "$project_settings_file" ]] && [[ ! -f "$project_hooks_file" ]]; then
        warning "No project-specific notifications to disable"
        info "Global settings will apply to this project"
        return 0
    fi
    
    if [[ -f "$project_settings_file" ]]; then
        backup_config "$project_settings_file"
        disable_project_hooks_in_settings "$project_root" || return 1
        removed_any=1
    fi

    if [[ -f "$project_hooks_file" ]]; then
        backup_config "$project_hooks_file"
        rm -f "$project_hooks_file"
        removed_any=1
    fi

    if [[ $removed_any -eq 0 ]]; then
        warning "No project-specific notifications to disable"
        info "Global settings will apply to this project"
        return 0
    fi

    success "Project notifications DISABLED"
    
    # Check if .claude directory is empty and remove if so
    if [[ -d "$project_root/.claude" ]] && [[ -z "$(ls -A "$project_root/.claude")" ]]; then
        rmdir "$project_root/.claude"
    fi
    
    # Show what will happen now
    echo ""
    if is_enabled_globally; then
        info "This project will now use global notification settings"
        if [[ -f "$HOME/.claude/notifications/disabled" ]]; then
            status_disabled "Global notifications are MUTED by the kill switch"
        else
            status_enabled "Global notifications are ENABLED"
        fi
    else
        info "No notifications will be sent for this project"
        status_disabled "Global notifications are DISABLED"
    fi
}

# Show project-specific status
show_project_status() {
    local project_name=$(get_project_name)
    local project_root=$(get_project_root)
    local project_settings_file="$project_root/.claude/settings.json"
    local project_hooks_file="$project_root/.claude/hooks.json"
    
    header "${FOLDER} Project Notification Status"
    echo ""
    echo "Project: ${BOLD}$project_name${RESET}"
    echo "Location: $project_root"
    echo ""
    
    # Check project status
    if is_enabled_project; then
        status_enabled "Project notifications: ENABLED"
        if is_enabled_project_settings; then
            info "Config: $project_settings_file"
        else
            info "Config: $project_hooks_file (legacy)"
        fi
        echo ""
        dim "Project settings override global settings, including the global mute file"
    else
        status_disabled "Project notifications: DISABLED"
        echo ""
        # Show global status
        if is_enabled_globally; then
            info "Using global notification settings"
            if [[ -f "$HOME/.claude/notifications/disabled" ]]; then
                status_disabled "Global notifications: MUTED by the kill switch"
            else
                status_enabled "Global notifications: ENABLED"
            fi
        else
            info "No notifications configured for this project"
            status_disabled "Global notifications: DISABLED"
        fi
    fi
    
    # Git information
    if is_git_repo; then
        echo ""
        dim "Git repository detected"
        local branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        dim "Current branch: $branch"
    fi
}

# Interactive project initialization
init_project_interactive() {
    local project_name=$(get_project_name)
    local project_root=$(get_project_root)
    
    header "${ROCKET} Initialize Notifications for: $project_name"
    echo ""
    echo "This will set up project-specific notifications that override global settings."
    echo ""
    
    # Show current status
    if is_enabled_project; then
        warning "Project notifications are already configured"
        echo ""
        read -p "Reconfigure notifications? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Setup cancelled"
            return 0
        fi
    fi
    
    # Check if git repo
    if is_git_repo; then
        info "Git repository detected"
        read -p "Add .claude/ to .gitignore? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if ! grep -q "^\.claude/$" .gitignore 2>/dev/null; then
                echo ".claude/" >> .gitignore
                success "Added .claude/ to .gitignore"
            else
                info ".claude/ already in .gitignore"
            fi
        fi
    fi
    
    # Enable notifications
    echo ""
    read -p "Enable notifications for this project? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        enable_notifications_project
    else
        info "Setup cancelled"
        echo ""
        echo "You can enable later with:"
        echo "  ${CYAN}cnp on${RESET}"
    fi
}

# Handle project voice commands
handle_project_voice_command() {
    local subcommand="${1:-status}"
    local project_root
    local project_name
    project_root=$(get_project_root)
    project_name=$(get_project_name)

    case "$subcommand" in
        "on")
            header "${SPEAKER} Setting Voice for Project: $project_name"
            echo ""

            # Show available voices
            info "Available voices for this project:"
            echo "  Popular choices:"
            echo "    - Samantha, Alex (American)"
            echo "    - Daniel, Oliver (British)"
            echo "    - Fiona (Scottish)"
            echo "    - Moira (Irish)"
            echo "    - Whisper (Whispering)"
            echo "    - Good News, Bad News (Novelty)"
            echo ""

            # Ask for voice preference
            read -p "Which voice for $project_name? (default: Samantha) " voice
            voice=${voice:-Samantha}

            # Enable project voice
            enable_voice "$voice" "project" "$project_root"
            success "Project voice set to: $voice"

            # Test it
            test_voice "$voice" "Voice notifications for $project_name will use $voice"
            ;;

        "off")
            header "${MUTE} Removing Project Voice Setting"
            echo ""
            if is_voice_enabled "project" "$project_root"; then
                disable_voice "project" "$project_root"
                success "Project voice setting removed"
                info "Will use global voice setting or default"
            else
                warning "No project voice setting to remove"
            fi
            ;;

        "status"|*)
            if is_voice_enabled "project" "$project_root"; then
                local current_voice
                current_voice=$(get_voice "project" "$project_root")
                status_enabled "Project voice: $current_voice"
            else
                status_disabled "Project voice: Not set (using global)"
                if is_voice_enabled "global"; then
                    local global_voice
                    global_voice=$(get_voice "global")
                    info "Global voice: $global_voice"
                fi
            fi
            ;;
    esac
}
