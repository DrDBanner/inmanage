#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_ENV_LOADED:-} ]] && return
__SERVICE_ENV_LOADED=1

# Resolve target env file (app or cli) and ensure it exists
resolve_env_file() {
    local target="${1:-app}"
    local path=""
    case "$target" in
        app)
            path="${INM_ENV_FILE:-}"
            if [[ "$path" == *\${* ]] && declare -F expand_placeholders >/dev/null; then
                path="$(expand_placeholders "$path")"
            fi
            ;;
        cli)
            path="${INM_SELF_ENV_FILE:-}"
            ;;
        *)
            log err "[ENV] Unknown env target: $target (use app|cli)"
            return 1
            ;;
    esac
    if [[ -z "$path" ]]; then
        log err "[ENV] No env file configured for target: $target"
        return 1
    fi
    if [[ ! -f "$path" ]]; then
        log err "[ENV] Env file not found: $path"
        return 1
    fi
    printf "%s" "$path"
}

env_show() {
    local target="${1:-app}"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    log info "[ENV] Showing env from $env_file"
    cat "$env_file"
}

env_get() {
    local target="app" key
    # allow: env get app KEY
    if [[ "$1" == "app" || "$1" == "cli" ]]; then
        target="$1"; shift
    fi
    key="$1"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    if [[ -z "$key" ]]; then
        log err "[ENV] Missing key. Usage: env get KEY"
        return 1
    fi
    local val
    val=$(grep -E "^${key}=" "$env_file" | tail -n1 | cut -d= -f2-)
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        log warn "[ENV] Key not found: $key"
    fi
}

env_unset() {
    local target="app" key
    if [[ "$1" == "app" || "$1" == "cli" ]]; then
        target="$1"; shift
    fi
    key="$1"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    if [[ -z "$key" ]]; then
        log err "[ENV] Missing key. Usage: env unset KEY"
        return 1
    fi
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would remove $key from $env_file"
        return 0
    fi
    if grep -q -E "^${key}=" "$env_file"; then
        local tmpfile
        tmpfile="$(mktemp)"
        grep -v -E "^${key}=" "$env_file" > "$tmpfile" && mv "$tmpfile" "$env_file"
        log ok "[ENV] Removed $key from $env_file"
    else
        log warn "[ENV] Key not found: $key"
    fi
}

env_set() {
    local target="app" pair
    if [[ "$1" == "app" || "$1" == "cli" ]]; then
        target="$1"; shift
    fi
    pair="$1"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    if [[ -z "$pair" || "$pair" != *=* ]]; then
        log err "[ENV] Usage: env set [app|cli] KEY=VALUE"
        return 1
    fi
    local key="${pair%%=*}"
    local value="${pair#*=}"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would set $key in $env_file"
        return 0
    fi
    local tmpfile
    tmpfile="$(mktemp)"
    # remove existing
    grep -v -E "^${key}=" "$env_file" > "$tmpfile" 2>/dev/null || true
    echo "${key}=${value}" >> "$tmpfile"
    mv "$tmpfile" "$env_file"
    log ok "[ENV] Set $key in $env_file"
}
