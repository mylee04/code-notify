#!/bin/bash

# Click-through configuration for macOS notifications.
# Maps TERM_PROGRAM values to bundle IDs used by terminal-notifier -activate.

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

click_through_get_bundle_id() {
    local app_path="$1"
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist" 2>/dev/null
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

click_through_has_entries() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && return 0
    done < <(click_through_each_entry)
    return 1
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

click_through_write_entries() {
    local entries="$1"
    mkdir -p "$(dirname "$CLICK_THROUGH_CONFIG")"

    {
        echo "# Code-Notify click-through configuration"
        echo "# Maps TERM_PROGRAM values to macOS bundle IDs"
        echo ""
        if [[ -n "$entries" ]]; then
            printf '%s\n' "$entries"
        fi
    } > "$CLICK_THROUGH_CONFIG"
}

upsert_click_through_entry() {
    local term_prog="$1"
    local bundle_id="$2"
    local entries=""
    local line key value

    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$key" == "$term_prog" ]] || [[ "$value" == "$bundle_id" ]]; then
            continue
        fi
        [[ -n "$entries" ]] && entries+=$'\n'
        entries+="$line"
    done < <(click_through_each_entry)

    [[ -n "$entries" ]] && entries+=$'\n'
    entries+="${term_prog}=${bundle_id}"
    click_through_write_entries "$entries"
}

remove_click_through_entry() {
    local target="$1"
    local entries=""
    local removed=1
    local line key value

    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$key" == "$target" ]] || [[ "$value" == "$target" ]]; then
            removed=0
            continue
        fi
        [[ -n "$entries" ]] && entries+=$'\n'
        entries+="$line"
    done < <(click_through_each_entry)

    if [[ $removed -ne 0 ]]; then
        return 1
    fi

    click_through_write_entries "$entries"
    return 0
}

detect_parent_app_path() {
    local pid=$$
    local parent command app_path

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

collect_click_through_search_results() {
    local query="$1"
    local line candidate query_lower seen=""

    while IFS= read -r line; do
        [[ -d "$line" ]] || continue
        case "$seen" in
            *"|$line|"*) continue ;;
        esac
        seen="${seen}|${line}|"
        printf '%s\n' "$line"
    done < <(mdfind "kMDItemContentTypeTree == 'com.apple.application-bundle' && kMDItemFSName == '*${query}*'c" 2>/dev/null | head -20)

    query_lower=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')
    for candidate in /Applications/*.app /Applications/**/*.app "$HOME/Applications"/*.app; do
        [[ -d "$candidate" ]] || continue
        if [[ "$(basename "$candidate" .app | tr '[:upper:]' '[:lower:]')" == *"$query_lower"* ]]; then
            case "$seen" in
                *"|$candidate|"*) continue ;;
            esac
            seen="${seen}|${candidate}|"
            printf '%s\n' "$candidate"
        fi
    done
}

select_click_through_result() {
    local -a results=("$@")
    local idx choice bundle_id

    if [[ ${#results[@]} -eq 1 ]]; then
        printf '%s\n' "${results[0]}"
        return 0
    fi

    echo ""
    echo "  Found ${#results[@]} apps:"
    echo ""
    for idx in "${!results[@]}"; do
        bundle_id=$(click_through_get_bundle_id "${results[$idx]}")
        printf '  %s%2d)%s %-24s %s%s%s\n' \
            "$BOLD" "$((idx + 1))" "$RESET" \
            "$(basename "${results[$idx]}" .app)" \
            "$DIM" "$bundle_id" "$RESET"
    done

    echo ""
    printf '  Select [1-%d]: ' "${#results[@]}"
    read -r choice

    if [[ -z "$choice" ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#results[@]} ]] 2>/dev/null; then
        error "Invalid selection."
        return 1
    fi

    printf '%s\n' "${results[$((choice - 1))]}"
}

resolve_click_through_app_path() {
    local query="$1"
    local -a results=()
    local line

    if [[ -z "$query" ]]; then
        return 1
    fi

    if [[ -d "$query" ]] && [[ "$query" == *.app ]]; then
        printf '%s\n' "$query"
        return 0
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] && results+=("$line")
    done < <(collect_click_through_search_results "$query")

    [[ ${#results[@]} -gt 0 ]] || return 1
    select_click_through_result "${results[@]}"
}

show_click_through_status() {
    local line key value

    if ! click_through_has_entries; then
        info "No click-through mappings found. Run ${BOLD}cn click-through add${RESET} to set up."
        return 0
    fi

    echo ""
    header "  Click-Through Mappings"
    echo ""

    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        printf '  %s%-20s%s -> %s%s%s\n' "$BOLD" "$key" "$RESET" "$DIM" "$value" "$RESET"
    done < <(click_through_each_entry)

    echo ""
    dim "  Config: ${CLICK_THROUGH_CONFIG}"
}

run_click_through_add() {
    local query="${1:-}"
    local app_path=""
    local bundle_id app_name term_prog default_term input

    echo ""
    header "  Add Click-Through App"

    if [[ -z "$query" ]]; then
        app_path=$(detect_parent_app_path 2>/dev/null || true)
        if [[ -n "$app_path" ]]; then
            query="$app_path"
        else
            printf '  Enter app name or path to .app: '
            read -r query
        fi
    fi

    [[ -n "$query" ]] || { error "No app provided."; return 1; }

    app_path=$(resolve_click_through_app_path "$query") || {
        error "No apps found matching: $query"
        return 1
    }

    bundle_id=$(click_through_get_bundle_id "$app_path")
    [[ -n "$bundle_id" ]] || { error "Could not read bundle ID from: $app_path"; return 1; }

    app_name=$(basename "$app_path" .app)
    if [[ -n "${TERM_PROGRAM:-}" ]] && [[ "$query" == "$app_path" ]]; then
        default_term="${TERM_PROGRAM}"
    else
        default_term=$(click_through_guess_term_program "$bundle_id" "$app_name")
    fi

    echo ""
    echo "  App:            ${BOLD}${app_name}${RESET}  ${DIM}(${bundle_id})${RESET}"
    echo "  TERM_PROGRAM:   ${BOLD}${default_term}${RESET}"
    echo ""
    dim "  Tip: run 'echo \$TERM_PROGRAM' in the app's terminal to verify"
    echo ""
    printf '  Save? Enter to confirm, or type a different TERM_PROGRAM: '
    read -r input

    term_prog="${input:-$default_term}"
    [[ -n "$term_prog" ]] || { error "TERM_PROGRAM cannot be empty."; return 1; }

    upsert_click_through_entry "$term_prog" "$bundle_id"
    echo ""
    success "Saved: TERM_PROGRAM=${term_prog} -> ${app_name} (${bundle_id})"
}

run_click_through_remove() {
    local target="${1:-}"
    local -a terms=()
    local -a bundles=()
    local line choice

    if ! click_through_has_entries; then
        info "No click-through mappings to remove."
        return 0
    fi

    if [[ -n "$target" ]]; then
        if remove_click_through_entry "$target"; then
            success "Removed: $target"
            return 0
        fi
        error "No mapping found for: $target"
        return 1
    fi

    while IFS= read -r line; do
        terms+=("${line%%=*}")
        bundles+=("${line#*=}")
    done < <(click_through_each_entry)

    echo ""
    header "  Remove Click-Through Entry"
    echo ""

    local idx
    for idx in "${!terms[@]}"; do
        printf '  %s%2d)%s %-20s  %s%s%s\n' \
            "$BOLD" "$((idx + 1))" "$RESET" \
            "${terms[$idx]}" \
            "$DIM" "${bundles[$idx]}" "$RESET"
    done

    echo ""
    printf '  Select to remove [1-%d] (or q to cancel): ' "${#terms[@]}"
    read -r choice

    case "$choice" in
        q|Q|"")
            dim "  Cancelled."
            return 0
            ;;
    esac

    if [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#terms[@]} ]] 2>/dev/null; then
        error "Invalid selection."
        return 1
    fi

    if remove_click_through_entry "${terms[$((choice - 1))]}"; then
        success "Removed: ${terms[$((choice - 1))]} -> ${bundles[$((choice - 1))]}"
        return 0
    fi

    error "Failed to remove mapping."
    return 1
}

show_click_through_help() {
    cat << EOF

${BOLD}cn click-through${RESET} - Configure which app opens when a notification is clicked

${BOLD}USAGE:${RESET}
    cn click-through [command] [args]

${BOLD}COMMANDS:${RESET}
    ${GREEN}status${RESET}           Show current mappings (default)
    ${GREEN}add${RESET} [name]       Add an app mapping (auto-detect or search)
    ${GREEN}remove${RESET} [target]  Remove a mapping by TERM_PROGRAM or bundle ID
    ${GREEN}reset${RESET}            Remove all custom mappings
    ${GREEN}help${RESET}             Show this help text

${BOLD}EXAMPLES:${RESET}
    cn click-through
    cn click-through add
    cn click-through add Ghostty
    cn click-through remove ghostty
    cn click-through reset

EOF
}

handle_click_through_command() {
    local action="${1:-status}"
    shift 2>/dev/null || true

    case "$action" in
        "status")
            show_click_through_status
            ;;
        "add")
            run_click_through_add "${1:-}"
            ;;
        "remove"|"rm")
            run_click_through_remove "${1:-}"
            ;;
        "reset")
            rm -f "$CLICK_THROUGH_CONFIG"
            success "Click-through mappings reset"
            ;;
        "help"|"-h"|"--help")
            show_click_through_help
            ;;
        *)
            error "Unknown click-through action: $action"
            show_click_through_help
            return 1
            ;;
    esac
}
