#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__RESOLVE_HELPER_LOADED:-} ]] && return
__RESOLVE_HELPER_LOADED=1

# Bring in prompt helper for sudo prompts
if ! declare -F prompt_confirm >/dev/null 2>&1; then
    prompt_helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prompt.sh"
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

expand_path_vars() {
    local path="$1"
    if [[ -z "$path" ]]; then
        printf "\n"
        return 0
    fi
    # Expand placeholders if helper exists, without eval
    local expanded="$path"
    if [[ "$expanded" == *\${* ]] && declare -F expand_placeholders >/dev/null; then
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

    local sudo_flags=()
    if [[ "$allow_prompt" != "true" ]]; then
        sudo_flags+=(-n)
    fi

    timeout 20 sudo "${sudo_flags[@]}" mkdir -p "$path" || return 1
    timeout 20 sudo "${sudo_flags[@]}" chown "${owner}:${owner}" "$path" || return 1
    timeout 20 sudo "${sudo_flags[@]}" chmod "$mode" "$path" || return 1
    return 0
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
        # Try user/home cache first
        if [ -w "$home_cache" ] || (mkdir -p "$home_cache" 2>/dev/null && chmod 755 "$home_cache" 2>/dev/null); then
            INM_GLOBAL_CACHE="$home_cache"
            log ok "[GC] Using cache: $INM_GLOBAL_CACHE"
            return 0
        fi

        # Try sudo non-interactively; if that fails, decide whether to prompt or fall back
        if command -v sudo >/dev/null 2>&1; then
            local cache_owner="${INM_ENFORCED_USER:-$USER}"
            if sudo_prepare_cache_dir "$home_cache" "$cache_owner" 755 false; then
                INM_GLOBAL_CACHE="$home_cache"
                log ok "[GC] Using cache via sudo: $INM_GLOBAL_CACHE"
                return 0
            fi
            # Only prompt if sudo non-interactive succeeds; otherwise avoid trapping for password
            if sudo -n true 2>/dev/null; then
                log note "[GC] Home cache not writable: $home_cache. Attempt sudo to fix perms/create? (y/N)"
                if prompt_confirm "GC_SUDO_CREATE_HOME" "no" "Create/fix cache at $home_cache with sudo?" false 20; then
                    if sudo_prepare_cache_dir "$home_cache" "$cache_owner" 755 true; then
                        INM_GLOBAL_CACHE="$home_cache"
                        log ok "[GC] Using cache via sudo: $INM_GLOBAL_CACHE"
                        return 0
                    else
                        log warn "[GC] Sudo creation failed for $home_cache."
                    fi
                else
                    log warn "[GC] Sudo creation declined for $home_cache."
                fi
            else
                log warn "[GC] Home cache not writable and sudo needs password; rerun with --override_enforced_user=true or pre-create $home_cache."
            fi
        fi
    else
        log warn "[GC] Cache parent not writable: $home_parent (perms/owner). Set INM_CACHE_GLOBAL_DIRECTORY to an accessible path or rerun with --override_enforced_user=true."
    fi

    # Fallback to project cache (normalize relative to cwd)
    INM_GLOBAL_CACHE="$project_cache"
    log warn "[GC] Falling back to project cache: $INM_GLOBAL_CACHE"
    mkdir -p "$INM_GLOBAL_CACHE" 2>/dev/null || true
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
    if [ ! -w "$parent_dir" ]; then
        log warn "[CACHE] Parent not writable for cache: $parent_dir (perms/owner). Set INM_CACHE_GLOBAL_DIRECTORY to accessible path or use --override_enforced_user=true."
        return 1
    fi
    if [ -w "$dir" ]; then
        return 0
    fi
    if [ ! -e "$dir" ]; then
        log note "[CACHE] Global cache missing or not accessible (perms?): $dir. Attempting to create/fix."
    else
        log warn "[CACHE] Global cache is not writable: $dir"
    fi
    if mkdir -p "$dir" 2>/dev/null && chmod 755 "$dir" 2>/dev/null; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        local cache_owner="${INM_ENFORCED_USER:-$USER}"
        if sudo_prepare_cache_dir "$dir" "$cache_owner" 755 false; then
            return 0
        fi
        if sudo -n true 2>/dev/null; then
            log note "[CACHE] Cache not writable: $dir. Attempt sudo to fix perms/create? (y/N)"
            if prompt_confirm "CACHE_SUDO_CREATE" "no" "Create/fix cache at $dir with sudo?" false 20; then
                if sudo_prepare_cache_dir "$dir" "$cache_owner" 755 true; then
                    return 0
                fi
                log warn "[CACHE] sudo creation failed for $dir; falling back to local cache"
            else
                log warn "[CACHE] Sudo creation declined for $dir; will use local cache."
            fi
        else
            log warn "[CACHE] Cache not writable and sudo needs password; rerun with --override_enforced_user=true or pre-create $dir."
        fi
    else
        log warn "[CACHE] Cannot create global cache (no perms). Will use local cache."
    fi
    return 1
}
