#!/bin/bash

CLICK_THROUGH_CONFIG="${CODE_NOTIFY_HOME:-$HOME/.code-notify}/click-through.conf"

click_through_guess_term_program() {
    case "$1" in
        com.mitchellh.ghostty) echo "ghostty" ;;
        com.googlecode.iterm2) echo "iTerm.app" ;;
        com.apple.Terminal) echo "Apple_Terminal" ;;
        com.microsoft.VSCode|com.microsoft.VSCodeInsiders|com.vscodium) echo "vscode" ;;
        com.todesktop.230313mzl4w4u92) echo "cursor" ;;
        dev.zed.Zed) echo "zed" ;;
        com.github.wez.wezterm) echo "WezTerm" ;;
        org.alacritty) echo "Alacritty" ;;
        co.zeit.hyper) echo "Hyper" ;;
        dev.warp.Warp-Stable) echo "WarpTerminal" ;;
        net.kovidgoyal.kitty) echo "kitty" ;;
        com.apple.dt.Xcode) echo "Xcode" ;;
        *)
            local fallback="${2:-app}"
            printf '%s\n' "$fallback" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd '[:alnum:]_.-'
            ;;
    esac
}

click_through_get_builtin_bundle_id_for_term_program() {
    case "$1" in
        "ghostty") echo "com.mitchellh.ghostty" ;;
        "iTerm.app") echo "com.googlecode.iterm2" ;;
        "Apple_Terminal") echo "com.apple.Terminal" ;;
        "vscode") echo "com.microsoft.VSCode" ;;
        "cursor") echo "com.todesktop.230313mzl4w4u92" ;;
        "zed") echo "dev.zed.Zed" ;;
        "WezTerm") echo "com.github.wez.wezterm" ;;
        "Alacritty") echo "org.alacritty" ;;
        "Hyper") echo "co.zeit.hyper" ;;
        *)
            return 1
            ;;
    esac
}

click_through_get_fallback_bundle_id() {
    if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
        echo "com.mitchellh.ghostty"
    elif [[ -n "${ITERM_SESSION_ID:-}" ]]; then
        echo "com.googlecode.iterm2"
    elif [[ -n "${WEZTERM_PANE:-}" ]]; then
        echo "com.github.wez.wezterm"
    else
        echo "com.apple.Terminal"
    fi
}

click_through_get_bundle_id() {
    local app_path="$1"
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist" 2>/dev/null
}

click_through_detect_parent_app_path() {
    local pid=$$
    local parent command app_path

    if [[ -n "${CODE_NOTIFY_CLICK_THROUGH_APP_PATH:-}" ]] && [[ -d "${CODE_NOTIFY_CLICK_THROUGH_APP_PATH}" ]]; then
        printf '%s\n' "${CODE_NOTIFY_CLICK_THROUGH_APP_PATH}"
        return 0
    fi

    while [[ "$pid" -gt 1 ]]; do
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -n "$parent" ]] || return 1
        pid="$parent"
        command=$(ps -o command= -p "$pid" 2>/dev/null || true)

        if [[ "$command" == *".app/Contents/MacOS/"* ]]; then
            app_path="${command%%.app/Contents/MacOS/*}.app"
            if [[ "$app_path" != *"/Contents/Frameworks/"* ]] && [[ -d "$app_path" ]]; then
                printf '%s\n' "$app_path"
                return 0
            fi
        fi
    done

    return 1
}

click_through_get_context_bundle_id() {
    local app_path bundle_id

    app_path=$(click_through_detect_parent_app_path 2>/dev/null || true)
    if [[ -n "$app_path" ]]; then
        bundle_id=$(click_through_get_bundle_id "$app_path")
        if [[ -n "$bundle_id" ]]; then
            printf '%s\n' "$bundle_id"
            return 0
        fi
    fi

    if [[ -n "${__CFBundleIdentifier:-}" ]]; then
        printf '%s\n' "${__CFBundleIdentifier}"
        return 0
    fi

    return 1
}

click_through_get_runtime_term_program() {
    local term_prog

    for term_prog in "${TERM_PROGRAM:-}" "${TERMINAL_EMULATOR:-}" "${LC_TERMINAL:-}"; do
        if [[ -n "$term_prog" ]]; then
            printf '%s\n' "$term_prog"
            return 0
        fi
    done

    return 1
}

click_through_each_entry() {
    [[ -f "$CLICK_THROUGH_CONFIG" ]] || return 0

    local line key value
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ -z "$key" ]] && continue
        printf '%s=%s\n' "$key" "$value"
    done < "$CLICK_THROUGH_CONFIG"
}

click_through_lookup_bundle_id() {
    local term_prog="$1"
    local line key value

    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$key" == "$term_prog" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < <(click_through_each_entry)

    return 1
}

click_through_lookup_term_program_by_bundle_id() {
    local bundle_id="$1"
    local line key value

    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$value" == "$bundle_id" ]]; then
            printf '%s\n' "$key"
            return 0
        fi
    done < <(click_through_each_entry)

    return 1
}

click_through_lookup_bundle_id_for_current_context() {
    local term_prog bundle_id

    term_prog=$(click_through_get_runtime_term_program || true)
    if [[ -n "$term_prog" ]]; then
        bundle_id=$(click_through_lookup_bundle_id "$term_prog" || true)
        if [[ -n "$bundle_id" ]]; then
            printf '%s\n' "$bundle_id"
            return 0
        fi
    fi

    bundle_id=$(click_through_get_context_bundle_id || true)
    if [[ -n "$bundle_id" ]] && click_through_lookup_term_program_by_bundle_id "$bundle_id" >/dev/null 2>&1; then
        printf '%s\n' "$bundle_id"
        return 0
    fi

    return 1
}

click_through_get_preferred_term_program() {
    local bundle_id="$1"
    local app_name="$2"
    local term_prog

    term_prog=$(click_through_get_runtime_term_program || true)
    if [[ -n "$term_prog" ]]; then
        printf '%s\n' "$term_prog"
        return 0
    fi

    if [[ -n "$bundle_id" ]]; then
        term_prog=$(click_through_lookup_term_program_by_bundle_id "$bundle_id" || true)
        if [[ -n "$term_prog" ]]; then
            printf '%s\n' "$term_prog"
            return 0
        fi
    fi

    click_through_guess_term_program "$bundle_id" "$app_name"
}
