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
            # shellcheck disable=SC2016
            if [[ "$path" == *'${'* ]] && declare -F expand_placeholders >/dev/null; then
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

_env_owner_for() {
    local env_file="$1"
    local og owner
    og="$(_fs_get_owner "$env_file")"
    owner="${og%%:*}"
    if [[ -z "$owner" || "$owner" == "$og" ]]; then
        owner="${INM_ENFORCED_USER:-}"
    fi
    if [[ -z "$owner" ]]; then
        owner="$(whoami 2>/dev/null || true)"
    fi
    printf "%s" "$owner"
}

_env_access_mode() {
    local env_file="$1"
    local mode="${2:-read}"
    local need_write=false
    if [[ "$mode" == "write" ]]; then
        need_write=true
    fi
    if [[ -r "$env_file" && ( "$need_write" == false || -w "$env_file" ) ]]; then
        echo "direct"
        return 0
    fi
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        echo "direct"
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        log err "[ENV] ${env_file} not ${mode}able and sudo is unavailable."
        return 1
    fi
    if sudo -n true 2>/dev/null; then
        echo "sudo"
        return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        log err "[ENV] ${env_file} not ${mode}able and no TTY for sudo prompt."
        return 1
    fi
    if prompt_confirm "ENV_SUDO" "no" "Env file not ${mode}able (${env_file}). Use sudo to proceed? [y/N]" false 60; then
        echo "sudo"
        return 0
    fi
    log err "[ENV] Insufficient permissions for ${env_file} (run as owner or with sudo)."
    return 1
}

_env_run() {
    local access="$1"
    local owner="$2"
    shift 2
    if [[ "$access" == "sudo" ]]; then
        sudo -u "$owner" -- "$@"
    else
        "$@"
    fi
}

_env_run_shell() {
    local access="$1"
    local owner="$2"
    local cmd="$3"
    shift 3
    if [[ "$access" == "sudo" ]]; then
        sudo -u "$owner" -- env "$@" bash -c "$cmd"
    else
        env "$@" bash -c "$cmd"
    fi
}

env_show() {
    local target="${1:-app}"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    local access owner
    access="$(_env_access_mode "$env_file" "read")" || return 1
    owner="$(_env_owner_for "$env_file")"
    log info "[ENV] Showing env from $env_file"
    _env_run "$access" "$owner" cat "$env_file"
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
    local access owner
    access="$(_env_access_mode "$env_file" "read")" || return 1
    owner="$(_env_owner_for "$env_file")"
    if [[ -z "$key" ]]; then
        log err "[ENV] Missing key. Usage: env get KEY"
        return 1
    fi
    local val
    val=$(_env_run "$access" "$owner" cat "$env_file" | grep -E "^${key}=" | tail -n1 | cut -d= -f2-)
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
    local access owner
    access="$(_env_access_mode "$env_file" "write")" || return 1
    owner="$(_env_owner_for "$env_file")"
    if [[ -z "$key" ]]; then
        log err "[ENV] Missing key. Usage: env unset KEY"
        return 1
    fi
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would remove $key from $env_file"
        return 0
    fi
    if grep -q -E "^${key}=" "$env_file"; then
        local cmd
        # shellcheck disable=SC2016
        cmd='tmp=$(mktemp) || exit 1; grep -v -E "^${KEY}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true; mv "$tmp" "$ENV_FILE"'
        _env_run_shell "$access" "$owner" "$cmd" KEY="$key" ENV_FILE="$env_file"
        if [[ "$target" == "app" && -n "${INM_ENV_MODE:-}" ]]; then
            _env_run "$access" "$owner" chmod "${INM_ENV_MODE}" "$env_file" 2>/dev/null || true
        fi
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
    local access owner
    access="$(_env_access_mode "$env_file" "write")" || return 1
    owner="$(_env_owner_for "$env_file")"
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
    local cmd
    # shellcheck disable=SC2016
    cmd='tmp=$(mktemp) || exit 1; grep -v -E "^${KEY}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true; printf "%s\n" "${KEY}=${VALUE}" >> "$tmp"; mv "$tmp" "$ENV_FILE"'
    _env_run_shell "$access" "$owner" "$cmd" KEY="$key" VALUE="$value" ENV_FILE="$env_file"
    if [[ "$target" == "app" && -n "${INM_ENV_MODE:-}" ]]; then
        _env_run "$access" "$owner" chmod "${INM_ENV_MODE}" "$env_file" 2>/dev/null || true
    fi
    log ok "[ENV] Set $key in $env_file"
}
