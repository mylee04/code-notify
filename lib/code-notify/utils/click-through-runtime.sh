#!/bin/bash

click_through_normalize_term_program() {
    local fallback="${1:-app}"
    printf '%s\n' "$fallback" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd '[:alnum:]_.-'
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
