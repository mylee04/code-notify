#!/bin/bash

# Click-through configuration for macOS notifications.
# Maps TERM_PROGRAM values to bundle IDs used by terminal-notifier -activate.

CLICK_THROUGH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLICK_THROUGH_DIR/click-through-store.sh"
source "$CLICK_THROUGH_DIR/click-through-runtime.sh"
source "$CLICK_THROUGH_DIR/click-through-resolver.sh"

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
    done < <(click_through_each_config_entry)

    echo ""
    dim "  Config: ${CLICK_THROUGH_CONFIG}"
}

run_click_through_add() {
    local query="${1:-}"
    local app_path=""
    local bundle_id app_name term_prog default_term input
    local auto_detected=0 existing_term

    echo ""
    header "  Add Click-Through App"

    if [[ -z "$query" ]]; then
        app_path=$(click_through_detect_parent_app_path 2>/dev/null || true)
        if [[ -n "$app_path" ]]; then
            query="$app_path"
            auto_detected=1
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
    default_term=$(click_through_resolve_default_term_program "$bundle_id" "$app_name")

    if [[ "$auto_detected" -eq 1 ]]; then
        existing_term=$(click_through_find_existing_mapping_term_program "$bundle_id" || true)
        if [[ -n "$existing_term" ]]; then
            echo ""
            info "Mapping already exists: ${BOLD}${existing_term}${RESET} -> ${DIM}${bundle_id}${RESET}"
            dim "  Run ${BOLD}cn click-through remove${RESET} to delete it."
            return 0
        fi
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

    click_through_upsert_entry "$term_prog" "$bundle_id"
    echo ""
    success "Saved: TERM_PROGRAM=${term_prog} -> ${app_name} (${bundle_id})"
}

draw_click_through_remove_item() {
    local idx="$1"
    local current="$2"
    local term_prog="$3"
    local bundle_id="$4"
    local is_selected="$5"
    local pointer="   "
    local checkbox="${DIM}[ ]${RESET}"
    local padded

    if [[ "$idx" -eq "$current" ]]; then
        pointer=" ${CYAN}>${RESET} "
    fi

    if [[ "$is_selected" -eq 1 ]]; then
        checkbox="${GREEN}[x]${RESET}"
    fi

    padded=$(printf '%-20s' "$term_prog")
    printf '\e[2K\r%s%s %s  %s%s%s\n' \
        "$pointer" "$checkbox" "$padded" \
        "$DIM" "$bundle_id" "$RESET"
}

draw_click_through_remove_footer() {
    local total="$1"
    shift
    local selected_count=0
    local value

    for value in "$@"; do
        [[ "$value" -eq 1 ]] && selected_count=$((selected_count + 1))
    done

    printf '\e[2K\r  %s%d / %d selected%s' "$DIM" "$selected_count" "$total" "$RESET"
}

run_click_through_remove() {
    local -a terms=()
    local -a bundles=()
    local -a selected=()
    local line

    if ! click_through_has_entries; then
        info "No click-through mappings to remove."
        return 0
    fi

    while IFS= read -r line; do
        terms+=("${line%%=*}")
        bundles+=("${line#*=}")
        selected+=(0)
    done < <(click_through_each_config_entry)

    echo ""
    header "  Remove Click-Through Entries"
    echo ""
    dim "  Up/Down move  Space toggle  Enter remove  q cancel"
    echo ""

    local idx current=0 total="${#terms[@]}"
    for idx in "${!terms[@]}"; do
        draw_click_through_remove_item "$idx" "$current" "${terms[$idx]}" "${bundles[$idx]}" "${selected[$idx]}"
    done
    draw_click_through_remove_footer "$total" "${selected[@]}"

    local key="" selected_count=0 entries="" removed_terms=""
    while true; do
        IFS= read -rsn1 key || true

        case "$key" in
            $'\x1b')
                read -rsn2 key || true
                case "$key" in
                    "[A")
                        [[ "$current" -gt 0 ]] && current=$((current - 1))
                        ;;
                    "[B")
                        [[ "$current" -lt $((total - 1)) ]] && current=$((current + 1))
                        ;;
                esac
                ;;
            " ")
                if [[ "${selected[$current]}" -eq 1 ]]; then
                    selected[$current]=0
                else
                    selected[$current]=1
                fi
                ;;
            ""|$'\n')
                break
                ;;
            "q"|"Q")
                echo ""
                echo ""
                dim "  Cancelled."
                return 0
                ;;
        esac

        printf '\e[%dA' "$total"
        for idx in "${!terms[@]}"; do
            draw_click_through_remove_item "$idx" "$current" "${terms[$idx]}" "${bundles[$idx]}" "${selected[$idx]}"
        done
        draw_click_through_remove_footer "$total" "${selected[@]}"
    done

    for idx in "${!terms[@]}"; do
        if [[ "${selected[$idx]}" -eq 1 ]]; then
            selected_count=$((selected_count + 1))
            [[ -n "$removed_terms" ]] && removed_terms+=", "
            removed_terms+="${terms[$idx]}"
            continue
        fi
        [[ -n "$entries" ]] && entries+=$'\n'
        entries+="${terms[$idx]}=${bundles[$idx]}"
    done

    if [[ "$selected_count" -eq 0 ]]; then
        echo ""
        echo ""
        info "No mappings selected."
        return 0
    fi

    click_through_write_entries "$entries"
    echo ""
    echo ""
    success "Removed ${selected_count} mapping(s): ${removed_terms}"
}

show_click_through_help() {
    cat << EOF

${BOLD}cn click-through${RESET} - Configure which app opens when a notification is clicked

${BOLD}USAGE:${RESET}
    cn click-through [command] [args]

${BOLD}COMMANDS:${RESET}
    ${GREEN}status${RESET}           Show current mappings (default)
    ${GREEN}add${RESET} [name]       Add an app mapping (auto-detect or search)
    ${GREEN}remove${RESET}           Interactively remove one or more mappings
    ${GREEN}reset${RESET}            Remove all custom mappings
    ${GREEN}help${RESET}             Show this help text

    Note: controls which app Code-Notify activates when you click a macOS notification.

${BOLD}EXAMPLES:${RESET}
    cn click-through
    cn click-through add
    cn click-through add Ghostty
    cn click-through remove
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
            run_click_through_remove
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
