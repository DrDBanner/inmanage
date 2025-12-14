#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_ENV_LOADED:-} ]] && return
__SERVICE_ENV_LOADED=1

# Ensure target env file is known
ensure_app_env_file() {
    if [[ -z "${INM_ENV_FILE:-}" ]]; then
        log err "[ENV] No INM_ENV_FILE set. Run health/info once or provide --ninja-location."
        return 1
    fi
    if [[ ! -f "$INM_ENV_FILE" ]]; then
        log err "[ENV] Env file not found: $INM_ENV_FILE"
        return 1
    fi
    return 0
}

env_show() {
    ensure_app_env_file || return 1
    log info "[ENV] Showing env from $INM_ENV_FILE"
    cat "$INM_ENV_FILE"
}

env_get() {
    ensure_app_env_file || return 1
    local key="$1"
    if [[ -z "$key" ]]; then
        log err "[ENV] Missing key. Usage: env get KEY"
        return 1
    fi
    local val
    val=$(grep -E "^${key}=" "$INM_ENV_FILE" | tail -n1 | cut -d= -f2-)
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        log warn "[ENV] Key not found: $key"
    fi
}

env_unset() {
    ensure_app_env_file || return 1
    local key="$1"
    if [[ -z "$key" ]]; then
        log err "[ENV] Missing key. Usage: env unset KEY"
        return 1
    fi
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would remove $key from $INM_ENV_FILE"
        return 0
    fi
    if grep -q -E "^${key}=" "$INM_ENV_FILE"; then
        local tmpfile
        tmpfile="$(mktemp)"
        grep -v -E "^${key}=" "$INM_ENV_FILE" > "$tmpfile" && mv "$tmpfile" "$INM_ENV_FILE"
        log ok "[ENV] Removed $key from $INM_ENV_FILE"
    else
        log warn "[ENV] Key not found: $key"
    fi
}

env_set() {
    ensure_app_env_file || return 1
    local pair="$1"
    if [[ -z "$pair" || "$pair" != *=* ]]; then
        log err "[ENV] Usage: env set KEY=VALUE"
        return 1
    fi
    local key="${pair%%=*}"
    local value="${pair#*=}"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would set $key in $INM_ENV_FILE"
        return 0
    fi
    local tmpfile
    tmpfile="$(mktemp)"
    # remove existing
    grep -v -E "^${key}=" "$INM_ENV_FILE" > "$tmpfile" 2>/dev/null || true
    echo "${key}=${value}" >> "$tmpfile"
    mv "$tmpfile" "$INM_ENV_FILE"
    log ok "[ENV] Set $key in $INM_ENV_FILE"
}
