#!/usr/bin/env bash

# ---------------------------------------------------------------------
# expand_path_vars()
# Expand ~ and $HOME placeholders without eval.
# Consumes: args: path; env: INM_ORIGINAL_HOME/HOME; deps: expand_placeholders (optional).
# Computes: expanded path.
# Returns: expanded path on stdout.
# ---------------------------------------------------------------------
expand_path_vars() {
    local path="$1"
    if [[ -z "$path" ]]; then
        printf "\n"
        return 0
    fi
    # Expand placeholders if helper exists, without eval
    local expanded="$path"
    # shellcheck disable=SC2016
    if [[ "$expanded" == *'${'* ]]; then
        expanded="$(expand_placeholders "$expanded")"
    fi
    # Expand leading ~ and simple $HOME/${HOME} without eval, prefer resolved home base
    local home_base
    resolve_home_base >/dev/null
    home_base="$INM_HOME_RESOLVED_BASE"
    expanded="${expanded/#\~/$home_base}"
    expanded="${expanded//\$\{HOME\}/$home_base}"
    expanded="${expanded//\$HOME/$home_base}"
    printf "%s\n" "$expanded"
}

# ---------------------------------------------------------------------
# resolve_user_home()
# Resolve home directory for a user.
# Consumes: args: user; tools: getent, pw.
# Computes: home path.
# Returns: home path on stdout (empty if unavailable).
# ---------------------------------------------------------------------
resolve_user_home() {
    local user="$1"
    [[ -z "$user" ]] && return 1

    local home=""
    if command -v getent >/dev/null 2>&1; then
        home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    elif command -v pw >/dev/null 2>&1; then
        home="$(pw usershow "$user" 2>/dev/null | awk -F: '{print $9}')"
    fi
    if [[ -z "$home" ]]; then
        home="$(eval echo "~$user" 2>/dev/null || true)"
    fi
    if [[ -n "$home" && "$home" != "~$user" && -d "$home" ]]; then
        printf "%s\n" "$home"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# resolve_enforced_cache_dir()
# Prefer existing enforced-user cache when running as root with override.
# Consumes: env: INM_OVERRIDE_ENFORCED_USER, INM_ENFORCED_USER, INM_CACHE_GLOBAL_DIRECTORY; deps: expand_path_vars.
# Computes: cache dir path.
# Returns: cache dir on stdout, 0 on success; 1 on failure.
# ---------------------------------------------------------------------
resolve_enforced_cache_dir() {
    if [[ "${INM_OVERRIDE_ENFORCED_USER:-}" != "true" ]]; then
        return 1
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        return 1
    fi
    local enforced_user="${INM_ENFORCED_USER:-}"
    if [[ -z "$enforced_user" || "$enforced_user" == "root" ]]; then
        return 1
    fi

    local enforced_home=""
    enforced_home="$(resolve_user_home "$enforced_user")" || return 1

    local cache_dir=""
    local INM_HOME_RESOLVED_BASE="$enforced_home"
    cache_dir="$(expand_path_vars "${INM_CACHE_GLOBAL_DIRECTORY:-$HOME/.cache/inmanage}")"
    if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
        printf "%s\n" "$cache_dir"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# sudo_prepare_cache_dir()
# Create/chown/chmod a cache directory via sudo.
# Consumes: args: path, owner, mode, allow_prompt, group; tools: sudo, timeout.
# Computes: directory setup with ownership and mode.
# Returns: 0 on success, 1 on failure.
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

# ---------------------------------------------------------------------
# cache_dir_mode()
# Resolve directory mode for cache paths.
# Consumes: env: INM_CACHE_DIR_MODE/INM_ENFORCED_GROUP.
# Computes: mode string.
# Returns: mode on stdout.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# cache_file_mode()
# Resolve file mode for cache files.
# Consumes: env: INM_CACHE_FILE_MODE/INM_ENFORCED_GROUP.
# Computes: mode string.
# Returns: mode on stdout.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# apply_cache_dir_mode()
# Apply cache directory mode to a path.
# Consumes: args: dir; deps: cache_dir_mode; tools: chmod.
# Computes: chmod on dir.
# Returns: 0 always (warnings ignored).
# ---------------------------------------------------------------------
apply_cache_dir_mode() {
    local dir="$1"
    local mode
    mode="$(cache_dir_mode)"
    chmod "$mode" "$dir" 2>/dev/null || true
}

# ---------------------------------------------------------------------
# resolve_cache_directory()
# Choose global or local cache based on permissions.
# Consumes: env: INM_CACHE_GLOBAL_DIRECTORY/INM_CACHE_LOCAL_DIRECTORY.
# Computes: writable cache directory.
# Returns: selected cache dir on stdout.
# ---------------------------------------------------------------------
resolve_cache_directory() {
    local enforced_cache=""
    enforced_cache="$(resolve_enforced_cache_dir 2>/dev/null || true)"
    if [[ -n "$enforced_cache" ]]; then
        log debug "[CACHE] Using enforced user cache: $enforced_cache"
        echo "$enforced_cache"
        return 0
    fi

    local global_path local_path
    global_path="$(expand_path_vars "${INM_CACHE_GLOBAL_DIRECTORY}")"
    local_path="$(expand_path_vars "${INM_CACHE_LOCAL_DIRECTORY}")"
    if check_global_cache_permissions; then
        echo "$global_path"
    else
        if [[ -n "$local_path" && ! -d "$local_path" ]]; then
            mkdir -p "$local_path" 2>/dev/null || true
        fi
        if [[ -n "$local_path" && -d "$local_path" ]]; then
            apply_cache_dir_mode "$local_path"
        fi
        echo "$local_path"
    fi
}

# ---------------------------------------------------------------------
# resolve_global_cache_dir()
# Determine usable global cache directory for downloads.
# Consumes: env: INM_CACHE_*; deps: apply_cache_dir_mode/sudo_prepare_cache_dir.
# Computes: INM_GLOBAL_CACHE.
# Returns: 0 if global usable, 1 if fallback to project cache.
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
# Verify/create global cache dir with sudo fallback.
# Consumes: env: INM_CACHE_*; deps: sudo_prepare_cache_dir/prompt_confirm/env_set.
# Computes: cache dir readiness.
# Returns: 0 if global cache usable, 1 if not.
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
        elif [[ -t 0 ]]; then
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
                if [ -f "${INM_SELF_ENV_FILE:-}" ]; then
                    env_set cli "INM_CACHE_SUDO_PROMPT=\"off\"" >/dev/null 2>&1 || true
                fi
            fi
        fi
    fi

    log debug "[CACHE] Using local cache."
    return 1
}
