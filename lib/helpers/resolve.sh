#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__RESOLVE_HELPER_LOADED:-} ]] && return
__RESOLVE_HELPER_LOADED=1

# Bring in prompt helper for sudo prompts
if ! declare -F prompt_confirm >/dev/null 2>&1; then
    prompt_helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prompt.sh"
    # shellcheck source=/dev/null
    [ -f "$prompt_helper_path" ] && source "$prompt_helper_path"
fi

# ---------------------------------------------------------------------
# resolve_script_path()
#
# Resolves a script path across symlinks using realpath/readlink fallback.
# ---------------------------------------------------------------------
resolve_script_path() {
    local target="$1"

    if command -v realpath >/dev/null 2>&1; then
        realpath "$target" && return
    fi

    if readlink -f "$target" >/dev/null 2>&1; then
        readlink -f "$target" && return
    fi

    (
        cd "$(dirname "$target")" 2>/dev/null || exit 1
        # shellcheck disable=SC2155
        local file="$(basename "$target")"
        while [ -L "$file" ]; do
            file="$(readlink "$file")"
            cd "$(dirname "$file")" 2>/dev/null || break
            file="$(basename "$file")"
        done
        printf "%s/%s\n" "$(pwd -P)" "$file"
    )
}

# ---------------------------------------------------------------------
# resolve_env_paths()
#
# Detects Invoice Ninja .env and related paths via flags or heuristic.
# Sets INM_SELF_ENV_FILE, INM_ENV_FILE, INM_BASE_DIRECTORY, INM_INSTALLATION_DIRECTORY, INM_INSTALLATION_PATH.
# ---------------------------------------------------------------------
resolve_env_paths() {
    log debug "[RES] Resolving environment paths... (args: $*)"

    unset -v INM_SELF_ENV_FILE INM_PROVISION_ENV_FILE INM_ENV_FILE INM_BASE_DIRECTORY INM_INSTALLATION_DIRECTORY INM_INSTALLATION_PATH

    if [ -n "${NAMED_ARGS[ninja_location]}" ]; then
        local ninja_dir="${NAMED_ARGS[ninja_location]}"
        # Treat boolean/empty values as unset
        if [[ "$ninja_dir" == "true" || "$ninja_dir" == "false" || -z "$ninja_dir" ]]; then
            log debug "[RES] Ignoring --ninja-location with non-path value: $ninja_dir"
            ninja_dir=""
        elif [[ "$ninja_dir" == --* ]] || [[ "$ninja_dir" != */* && "$ninja_dir" != .* ]]; then
            log debug "[RES] Ignoring invalid --ninja-location value: $ninja_dir"
            ninja_dir=""
        elif [ ! -f "$ninja_dir/.env" ]; then
            log warn "[RES] No .env found in --ninja-location: $ninja_dir (falling back to auto-detect)"
            ninja_dir=""
        else
            INM_BASE_DIRECTORY="$(dirname "$(realpath "$ninja_dir")")/"
            INM_INSTALLATION_DIRECTORY="$(basename "$ninja_dir")"
            INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
            INM_ENV_FILE="$ninja_dir/.env"
        log debug "[RES] Using .env from --ninja-location: $INM_ENV_FILE"
            if [ -z "${INM_SELF_ENV_FILE:-}" ] && [ -f "$INM_BASE_DIRECTORY/.inmanage/.env.inmanage" ]; then
                INM_SELF_ENV_FILE="$INM_BASE_DIRECTORY/.inmanage/.env.inmanage"
            fi
            return 0
        fi
    fi

    # If a local .inmanage/.env.inmanage exists, load it early to derive base/install
    if [ -f "$PWD/.inmanage/.env.inmanage" ]; then
        if [ -r "$PWD/.inmanage/.env.inmanage" ]; then
            log debug "[RES] Loading local config: $PWD/.inmanage/.env.inmanage"
            # shellcheck source=/dev/null
            source "$PWD/.inmanage/.env.inmanage"
            INM_SELF_ENV_FILE="$PWD/.inmanage/.env.inmanage"
        else
            log warn "[RES] Local config not readable: $PWD/.inmanage/.env.inmanage"
            INM_SELF_ENV_FILE="$PWD/.inmanage/.env.inmanage"
        fi
        if [ -n "${INM_BASE_DIRECTORY:-}" ] && [ -n "${INM_INSTALLATION_DIRECTORY:-}" ]; then
            INM_BASE_DIRECTORY="$(ensure_trailing_slash "${INM_BASE_DIRECTORY}")"
            INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
            INM_ENV_FILE="${INM_INSTALLATION_PATH%/}/.env"
            log debug "[RES] Derived from config: base=$INM_BASE_DIRECTORY install=$INM_INSTALLATION_DIRECTORY env=$INM_ENV_FILE"
            if [ -f "$INM_ENV_FILE" ]; then
                log debug "[RES] Using .env from existing project config, skipping discovery."
                return 0
            else
            log warn "[RES] App .env not found at $INM_ENV_FILE (from config); continuing discovery."
            fi
        fi
    fi

    local candidate_paths=(
        "$PWD/.inmanage"
        "$PWD"
        "$PWD/invoiceninja"   # common default install dir
        "$PWD/ninja"
        "$PWD/../.inmanage"
        "$PWD/.."
        "$HOME/.inmanage"
    )

    local candidates=()
    for dir in "${candidate_paths[@]}"; do
        [ -f "$dir/.env" ] && candidates+=("$dir/.env")
        log debug "[RES] Checked for .env in: $dir"
    done

    if [ ${#candidates[@]} -eq 0 ]; then
        if [ -z "${INM_ENV_FILE:-}" ]; then
            # Last resort: derive from base/install if set, otherwise warn only
            if [ -n "${INM_BASE_DIRECTORY:-}" ] && [ -n "${INM_INSTALLATION_DIRECTORY:-}" ]; then
                INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
                INM_ENV_FILE="${INM_INSTALLATION_PATH%/}/.env"
                log warn "[RES] No .env found; deriving path: $INM_ENV_FILE"
            else
                log warn "[RES] Could not find a usable .env file. Please specify --ninja-location=…"
                return 0
            fi
        fi
    elif [ ${#candidates[@]} -eq 1 ]; then
        INM_ENV_FILE="${candidates[0]}"
        log debug "[RES] Found .env: $INM_ENV_FILE"
    else
        if [ "${NAMED_ARGS[force]}" = true ]; then
            log err "[RES] Multiple .env files found, but --force was used. Cannot decide."
            exit 1
        fi
        INM_ENV_FILE="$(select_from_candidates "Select your Invoice Ninja .env file:" "${candidates[@]}")" || exit 1
    fi

    if [ -n "${INM_ENV_FILE:-}" ]; then
        if command -v realpath >/dev/null 2>&1; then
            INM_ENV_FILE="$(realpath "$INM_ENV_FILE" 2>/dev/null || echo "$INM_ENV_FILE")"
        fi
        INM_BASE_DIRECTORY="$(dirname "$(dirname "$INM_ENV_FILE")")/"
        INM_INSTALLATION_DIRECTORY="$(basename "$(dirname "$INM_ENV_FILE")")"
        INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"

        log debug "[RES] Detected base: $INM_BASE_DIRECTORY"
        log debug "[RES] Detected install dir: $INM_INSTALLATION_DIRECTORY"
        log debug "[RES] Install path: $INM_INSTALLATION_PATH"
        log debug "[RES] Using: $INM_ENV_FILE"
    fi

    # Prefer config alongside the base directory (not inside Invoice Ninja)
    # Respect explicit override via --config and allow relocatable config roots/basenames
    if [ -n "${NAMED_ARGS[config]:-}" ]; then
        # Ignore boolean/empty config values
        case "${NAMED_ARGS[config]}" in
            true|false|"") ;;
            *) INM_SELF_ENV_FILE="${NAMED_ARGS[config]}" ;;
        esac
    elif [ -z "${INM_SELF_ENV_FILE:-}" ] || [ ! -f "$INM_SELF_ENV_FILE" ]; then
        local config_root="${NAMED_ARGS[config_root]:-${INM_CONFIG_ROOT:-.inmanage}}"
        local config_basename="${INM_SELF_ENV_BASENAME:-.env.inmanage}"

        # Anchor relative config root to detected base directory
        if [[ "$config_root" != /* ]]; then
            config_root="${INM_BASE_DIRECTORY%/}/${config_root#/}"
        fi

        local cfg_candidates=(
            "${config_root%/}/${config_basename}"
            "${INM_BASE_DIRECTORY%/}/${config_basename}"          # backward compat if user placed it here
        )
        for cfg in "${cfg_candidates[@]}"; do
            if [ -f "$cfg" ]; then
                INM_SELF_ENV_FILE="$cfg"
                break
            fi
        done
        # If none exist, default to preferred location next to config_root
        if [ -z "${INM_SELF_ENV_FILE:-}" ]; then
            INM_SELF_ENV_FILE="${config_root%/}/${config_basename}"
        fi
    fi

    log debug "[RES] Config file resolved: ${INM_SELF_ENV_FILE:-<unset>}"
}

# ---------------------------------------------------------------------
# compute_installation_path()
# Normalizes installation path (supports absolute or relative dirs).
# ---------------------------------------------------------------------
compute_installation_path() {
    local base="$1"
    local dir="$2"

    if [[ "$dir" == /* ]]; then
        printf "%s\n" "${dir%/}"
    else
        printf "%s/%s\n" "${base%/}" "${dir#/}"
    fi
}

# ---------------------------------------------------------------------
# version_compare v1 (gt|lt|eq) v2
# Simple semantic-ish compare for dot-separated numbers.
# ---------------------------------------------------------------------
version_compare() {
    local v1="$1" op="$2" v2="$3"
    local IFS=.
    local a=() b=() i comp="eq"
    read -r -a a <<<"$v1"
    read -r -a b <<<"$v2"
    local len=${#a[@]}
    (( ${#b[@]} > len )) && len=${#b[@]}
    for ((i=${#a[@]}; i<len; i++)); do a[i]=0; done
    for ((i=${#b[@]}; i<len; i++)); do b[i]=0; done
    for ((i=0; i<len; i++)); do
        if ((10#${a[i]} > 10#${b[i]})); then comp="gt"; break
        elif ((10#${a[i]} < 10#${b[i]})); then comp="lt"; break
        fi
    done
    [[ "$comp" == "$op" ]]
}

expand_path_vars() {
    local path="$1"
    if [[ -z "$path" ]]; then
        printf "\n"
        return 0
    fi
    # Expand placeholders if helper exists, without eval
    local expanded="$path"
    # shellcheck disable=SC2016
    if [[ "$expanded" == *'${'* ]] && declare -F expand_placeholders >/dev/null; then
        expanded="$(expand_placeholders "$expanded")"
    fi
    # Expand leading ~ and simple $HOME/${HOME} without eval, prefer original home if preserved
    local home_base="${INM_ORIGINAL_HOME:-$HOME}"
    expanded="${expanded/#\~/$home_base}"
    expanded="${expanded//\$\{HOME\}/$home_base}"
    expanded="${expanded//\$HOME/$home_base}"
    printf "%s\n" "$expanded"
}

# ---------------------------------------------------------------------
# sudo_prepare_cache_dir()
# Creates/fixes a cache directory with sudo; optional promptless mode.
# Returns 0 on success, 1 otherwise.
# ---------------------------------------------------------------------
sudo_prepare_cache_dir() {
    local path="$1"
    local owner="$2"
    local mode="${3:-755}"
    local allow_prompt="${4:-false}"
    local group="${5:-}"
    if [[ -z "$group" ]]; then
        group="$(id -gn "$owner" 2>/dev/null || true)"
        [[ -z "$group" ]] && group="$owner"
    fi

    local sudo_flags=()
    if [[ "$allow_prompt" != "true" ]]; then
        sudo_flags+=(-n)
    fi

    timeout 20 sudo "${sudo_flags[@]}" mkdir -p "$path" || return 1
    timeout 20 sudo "${sudo_flags[@]}" chown "${owner}:${group}" "$path" || return 1
    timeout 20 sudo "${sudo_flags[@]}" chmod "$mode" "$path" || return 1
    return 0
}

cache_dir_mode() {
    if [[ -n "${INM_CACHE_DIR_MODE:-}" ]]; then
        printf "%s" "${INM_CACHE_DIR_MODE}"
        return
    fi
    if [[ -n "${INM_ENFORCED_GROUP:-}" ]]; then
        printf "775"
    else
        printf "750"
    fi
}

cache_file_mode() {
    if [[ -n "${INM_CACHE_FILE_MODE:-}" ]]; then
        printf "%s" "${INM_CACHE_FILE_MODE}"
        return
    fi
    if [[ -n "${INM_ENFORCED_GROUP:-}" ]]; then
        printf "664"
    else
        printf "640"
    fi
}

apply_cache_dir_mode() {
    local dir="$1"
    local mode
    mode="$(cache_dir_mode)"
    chmod "$mode" "$dir" 2>/dev/null || true
}

# ---------------------------------------------------------------------
# resolve_cache_directory()
# Chooses between global or local cache based on permissions.
# ---------------------------------------------------------------------
resolve_cache_directory() {
    local global_path local_path
    global_path="$(expand_path_vars "${INM_CACHE_GLOBAL_DIRECTORY}")"
    local_path="$(expand_path_vars "${INM_CACHE_LOCAL_DIRECTORY}")"
    if check_global_cache_permissions; then
        echo "$global_path"
    else
        echo "$local_path"
    fi
}

# ---------------------------------------------------------------------
# resolve_global_cache_dir()
# Determines usable global cache directory for downloads/tars.
# ---------------------------------------------------------------------
resolve_global_cache_dir() {
    local home_cache
    home_cache="$(expand_path_vars "${INM_CACHE_GLOBAL_DIRECTORY:-$HOME/.cache/inmanage}")"
    local project_cache
    project_cache="$(expand_path_vars "${INM_CACHE_LOCAL_DIRECTORY:-./.cache}")"
    local home_parent
    home_parent="$(dirname "$home_cache")"

    log debug "[GC] Resolving global cache directory..."

    if [ -w "$home_parent" ]; then
        if [ -w "$home_cache" ] || (mkdir -p "$home_cache" 2>/dev/null && apply_cache_dir_mode "$home_cache"); then
            INM_GLOBAL_CACHE="$home_cache"
            log ok "[GC] Using cache: $INM_GLOBAL_CACHE"
            return 0
        fi

        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            local cache_owner="${INM_ENFORCED_USER:-$USER}"
            local cache_group="${INM_ENFORCED_GROUP:-}"
            if sudo_prepare_cache_dir "$home_cache" "$cache_owner" "$(cache_dir_mode)" false "$cache_group"; then
                INM_GLOBAL_CACHE="$home_cache"
                log ok "[GC] Using cache via sudo: $INM_GLOBAL_CACHE"
                return 0
            fi
        fi
    else
        log debug "[GC] Cache parent not writable: $home_parent (perms/owner)."
    fi

    # Fallback to project cache (normalize relative to cwd)
    INM_GLOBAL_CACHE="$project_cache"
    log debug "[GC] Falling back to project cache: $INM_GLOBAL_CACHE"
    mkdir -p "$INM_GLOBAL_CACHE" 2>/dev/null || true
    apply_cache_dir_mode "$INM_GLOBAL_CACHE"
    return 1
}

# ---------------------------------------------------------------------
# check_global_cache_permissions()
# Verifies/creates global cache dir with sudo fallback.
# ---------------------------------------------------------------------
check_global_cache_permissions() {
    local dir
    dir="$(expand_path_vars "${INM_CACHE_GLOBAL_DIRECTORY:-$HOME/.cache/inmanage}")"
    local parent_dir
    parent_dir="$(dirname "$dir")"
    if [[ -z "${INM_CACHE_SUDO_PROMPT:-}" && -n "${INM_SELF_ENV_FILE:-}" && -r "$INM_SELF_ENV_FILE" ]]; then
        local cache_prompt
        cache_prompt=$(grep -E '^INM_CACHE_SUDO_PROMPT=' "$INM_SELF_ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' ')
        if [[ -n "$cache_prompt" ]]; then
            INM_CACHE_SUDO_PROMPT="$cache_prompt"
        fi
    fi
    if [ -w "$dir" ]; then
        return 0
    fi

    if [ -w "$parent_dir" ]; then
        if mkdir -p "$dir" 2>/dev/null && apply_cache_dir_mode "$dir"; then
            return 0
        fi
    fi

    if command -v sudo >/dev/null 2>&1; then
        local cache_owner="${INM_ENFORCED_USER:-$USER}"
        local cache_group="${INM_ENFORCED_GROUP:-}"
        if sudo -n true 2>/dev/null; then
            if sudo_prepare_cache_dir "$dir" "$cache_owner" "$(cache_dir_mode)" false "$cache_group"; then
                return 0
            fi
        elif [[ -t 0 ]] && declare -F prompt_confirm >/dev/null 2>&1; then
            if [[ "${INM_CACHE_SUDO_PROMPT:-ask}" =~ ^(0|no|false|never|off)$ ]]; then
                log debug "[CACHE] Using local cache."
                return 1
            fi
            if prompt_confirm "CACHE_SUDO" "no" "Global cache not writable at $dir. Use sudo to create and chown to ${cache_owner}? [y/N]" false 60; then
                if sudo_prepare_cache_dir "$dir" "$cache_owner" "$(cache_dir_mode)" true "$cache_group"; then
                    return 0
                fi
            else
                INM_CACHE_SUDO_PROMPT="off"
                if declare -F env_set >/dev/null 2>&1 && [ -f "${INM_SELF_ENV_FILE:-}" ]; then
                    env_set cli "INM_CACHE_SUDO_PROMPT=\"off\"" >/dev/null 2>&1 || true
                fi
            fi
        fi
    fi

    log debug "[CACHE] Using local cache."
    return 1
}
