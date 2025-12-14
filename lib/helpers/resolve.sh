#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__RESOLVE_HELPER_LOADED:-} ]] && return
__RESOLVE_HELPER_LOADED=1

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
            log ok "[RES] Using .env from --ninja-location: $INM_ENV_FILE"
            if [ -z "${INM_SELF_ENV_FILE:-}" ] && [ -f "$INM_BASE_DIRECTORY/.inmanage/.env.inmanage" ]; then
                INM_SELF_ENV_FILE="$INM_BASE_DIRECTORY/.inmanage/.env.inmanage"
            fi
            return 0
        fi
    fi

    # If a local .inmanage/.env.inmanage exists, load it early to derive base/install
    if [ -f "$PWD/.inmanage/.env.inmanage" ]; then
        log debug "[RES] Loading local config: $PWD/.inmanage/.env.inmanage"
        # shellcheck source=/dev/null
        source "$PWD/.inmanage/.env.inmanage"
        INM_SELF_ENV_FILE="$PWD/.inmanage/.env.inmanage"
        if [ -n "${INM_BASE_DIRECTORY:-}" ] && [ -n "${INM_INSTALLATION_DIRECTORY:-}" ]; then
            INM_BASE_DIRECTORY="$(ensure_trailing_slash "${INM_BASE_DIRECTORY}")"
            INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
            INM_ENV_FILE="${INM_INSTALLATION_PATH%/}/.env"
            log debug "[RES] Derived from config: base=$INM_BASE_DIRECTORY install=$INM_INSTALLATION_DIRECTORY env=$INM_ENV_FILE"
            if [ -f "$INM_ENV_FILE" ]; then
                log debug "[RES] Using .env from existing project config, skipping discovery."
                return 0
            else
                log warn "[RES] .env not found at $INM_ENV_FILE (from config); continuing discovery."
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

        log ok "[RES] Detected base: $INM_BASE_DIRECTORY"
        log ok "[RES] Detected install dir: $INM_INSTALLATION_DIRECTORY"
        log ok "[RES] Install path: $INM_INSTALLATION_PATH"
        log ok "[RES] Using: $INM_ENV_FILE"
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
    local a=($v1) b=($v2) i comp="eq"
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

# ---------------------------------------------------------------------
# resolve_cache_directory()
# Chooses between global or local cache based on permissions.
# ---------------------------------------------------------------------
resolve_cache_directory() {
    if check_global_cache_permissions; then
        echo "${INM_CACHE_GLOBAL_DIRECTORY}"
    else
        echo "${INM_CACHE_LOCAL_DIRECTORY}"
    fi
}

# ---------------------------------------------------------------------
# resolve_global_cache_dir()
# Determines usable global cache directory for downloads/tars.
# ---------------------------------------------------------------------
resolve_global_cache_dir() {
    local user_cache="${HOME}/.cache/inmanage"
    local root_cache="/var/cache/inmanage"

    log debug "[GC] Resolving global cache directory..."

    if [ -w "$user_cache" ]; then
        INM_GLOBAL_CACHE="$user_cache"
        log ok "[GC] Using user cache: $INM_GLOBAL_CACHE"
        return 0
    fi

    log warn "[GC] User cache not writable: $user_cache"

    if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        log note "[GC] Attempting sudo access for: $root_cache (timeout 20s)"
        if timeout 20 sudo mkdir -p "$root_cache" && timeout 20 sudo chown "$USER" "$root_cache"; then
            INM_GLOBAL_CACHE="$root_cache"
            log ok "[GC] Using system cache: $INM_GLOBAL_CACHE"
            return 0
        else
            log err "[GC] Failed to set up writable system cache at $root_cache"
            exit 1
        fi
    else
        log err "[GC] No writeable global cache available and no sudo rights."
        exit 1
    fi
}

# ---------------------------------------------------------------------
# check_global_cache_permissions()
# Verifies/creates global cache dir with sudo fallback.
# ---------------------------------------------------------------------
check_global_cache_permissions() {
    local dir="${INM_CACHE_GLOBAL_DIRECTORY:-$HOME/.cache/inmanage}"
    if [ -w "$dir" ]; then
        return 0
    elif [ ! -e "$dir" ]; then
        log note "[CACHE] Global cache does not exist. Attempting to create: $dir"
        # Try without sudo first
        if mkdir -p "$dir" 2>/dev/null && chmod 777 "$dir" 2>/dev/null; then
            return 0
        fi
        # Avoid interactive sudo; only attempt if non-interactive is available
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            if timeout 20s sudo mkdir -p "$dir" && timeout 20s sudo chmod 777 "$dir"; then
                return 0
            fi
            log warn "[CACHE] sudo creation failed for $dir; falling back to local cache"
        else
            log warn "[CACHE] Cannot create global cache (no perms). Will use local cache."
        fi
    else
        log warn "[CACHE] Global cache is not writable: $dir"
    fi
    return 1
}
