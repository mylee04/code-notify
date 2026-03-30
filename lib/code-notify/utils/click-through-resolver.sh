#!/bin/bash

# Requires click-through-store.sh and click-through-runtime.sh to be sourced first.

click_through_resolve_configured_bundle_id() {
    local term_prog bundle_id

    term_prog=$(click_through_get_runtime_term_program || true)
    if [[ -n "$term_prog" ]]; then
        bundle_id=$(click_through_lookup_config_bundle_id "$term_prog" || true)
        if [[ -n "$bundle_id" ]]; then
            printf '%s\n' "$bundle_id"
            return 0
        fi
    fi

    bundle_id=$(click_through_get_context_bundle_id || true)
    if [[ -n "$bundle_id" ]] && click_through_lookup_config_term_program "$bundle_id" >/dev/null 2>&1; then
        printf '%s\n' "$bundle_id"
        return 0
    fi

    return 1
}

click_through_resolve_activation_bundle_id() {
    local term_prog bundle_id

    bundle_id=$(click_through_resolve_configured_bundle_id || true)
    if [[ -n "$bundle_id" ]]; then
        printf '%s\n' "$bundle_id"
        return 0
    fi

    term_prog=$(click_through_get_runtime_term_program || true)
    if [[ -n "$term_prog" ]]; then
        bundle_id=$(click_through_lookup_builtin_bundle_id "$term_prog" || true)
        if [[ -n "$bundle_id" ]]; then
            printf '%s\n' "$bundle_id"
            return 0
        fi
    fi

    click_through_get_fallback_bundle_id
}

click_through_resolve_default_term_program() {
    local bundle_id="$1"
    local app_name="$2"
    local term_prog

    term_prog=$(click_through_get_runtime_term_program || true)
    if [[ -n "$term_prog" ]]; then
        printf '%s\n' "$term_prog"
        return 0
    fi

    if [[ -n "$bundle_id" ]]; then
        term_prog=$(click_through_lookup_config_term_program "$bundle_id" || true)
        if [[ -n "$term_prog" ]]; then
            printf '%s\n' "$term_prog"
            return 0
        fi

        term_prog=$(click_through_lookup_builtin_term_program "$bundle_id" || true)
        if [[ -n "$term_prog" ]]; then
            printf '%s\n' "$term_prog"
            return 0
        fi
    fi

    click_through_normalize_term_program "$app_name"
}

click_through_find_existing_mapping_term_program() {
    local bundle_id="$1"
    local term_prog existing_bundle

    term_prog=$(click_through_get_runtime_term_program || true)
    if [[ -n "$term_prog" ]]; then
        existing_bundle=$(click_through_lookup_config_bundle_id "$term_prog" || true)
        if [[ "$existing_bundle" == "$bundle_id" ]]; then
            printf '%s\n' "$term_prog"
            return 0
        fi
        return 1
    fi

    term_prog=$(click_through_lookup_config_term_program "$bundle_id" || true)
    if [[ -n "$term_prog" ]]; then
        printf '%s\n' "$term_prog"
        return 0
    fi

    return 1
}
