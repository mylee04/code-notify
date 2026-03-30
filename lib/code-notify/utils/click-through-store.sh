#!/bin/bash

CLICK_THROUGH_CONFIG="${CODE_NOTIFY_HOME:-$HOME/.code-notify}/click-through.conf"

click_through_each_builtin_entry() {
    cat <<'EOF'
ghostty=com.mitchellh.ghostty
iTerm.app=com.googlecode.iterm2
Apple_Terminal=com.apple.Terminal
vscode=com.microsoft.VSCode
cursor=com.todesktop.230313mzl4w4u92
zed=dev.zed.Zed
WezTerm=com.github.wez.wezterm
Alacritty=org.alacritty
Hyper=co.zeit.hyper
WarpTerminal=dev.warp.Warp-Stable
kitty=net.kovidgoyal.kitty
Xcode=com.apple.dt.Xcode
EOF
}

click_through_each_config_entry() {
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

click_through_lookup_value() {
    local key="$1"
    local source_fn="$2"
    local line entry_key entry_value

    while IFS= read -r line; do
        entry_key="${line%%=*}"
        entry_value="${line#*=}"
        if [[ "$entry_key" == "$key" ]]; then
            printf '%s\n' "$entry_value"
            return 0
        fi
    done < <("$source_fn")

    return 1
}

click_through_lookup_key() {
    local value="$1"
    local source_fn="$2"
    local line entry_key entry_value

    while IFS= read -r line; do
        entry_key="${line%%=*}"
        entry_value="${line#*=}"
        if [[ "$entry_value" == "$value" ]]; then
            printf '%s\n' "$entry_key"
            return 0
        fi
    done < <("$source_fn")

    return 1
}

click_through_lookup_config_bundle_id() {
    click_through_lookup_value "$1" click_through_each_config_entry
}

click_through_lookup_config_term_program() {
    click_through_lookup_key "$1" click_through_each_config_entry
}

click_through_lookup_builtin_bundle_id() {
    click_through_lookup_value "$1" click_through_each_builtin_entry
}

click_through_lookup_builtin_term_program() {
    click_through_lookup_key "$1" click_through_each_builtin_entry
}

click_through_has_entries() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && return 0
    done < <(click_through_each_config_entry)
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

click_through_upsert_entry() {
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
    done < <(click_through_each_config_entry)

    [[ -n "$entries" ]] && entries+=$'\n'
    entries+="${term_prog}=${bundle_id}"
    click_through_write_entries "$entries"
}

click_through_remove_entry() {
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
    done < <(click_through_each_config_entry)

    if [[ $removed -ne 0 ]]; then
        return 1
    fi

    click_through_write_entries "$entries"
    return 0
}
