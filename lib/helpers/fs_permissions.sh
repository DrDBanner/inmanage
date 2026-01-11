#!/usr/bin/env bash

# ---------------------------------------------------------------------
# enforce_ownership()
# Apply ownership recursively to existing paths.
# Consumes: args: paths; env: INM_ENFORCED_USER/INM_ENFORCED_GROUP; tools: chown, realpath.
# Computes: validates path safety and applies chown -R.
# Returns: 0 always; logs warnings on failures.
# ---------------------------------------------------------------------
enforce_ownership() {
    local paths=("$@")
    local owner="${INM_ENFORCED_USER:-${ENFORCED_USER:-}}"
    local group="${INM_ENFORCED_GROUP:-${ENFORCED_GROUP:-}}"
    if [[ -z "$owner" ]]; then
        log debug "[EU] No enforced user configured; skipping chown."
        return 0
    fi
    if [[ -z "$group" ]]; then
        group="$(id -gn "$owner" 2>/dev/null || true)"
        [[ -z "$group" ]] && group="$owner"
    fi
    local expected="${owner}:${group}"
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            local resolved
            resolved="$(realpath "$path" 2>/dev/null || echo "$path")"
            if [[ -z "$resolved" || "$resolved" == "/" ]]; then
                log warn "[EU] Refusing to chown unsafe path: ${path}"
                continue
            fi
            local current
            current="$(_fs_get_owner "$path")"
            if [[ "$current" == "$expected" ]]; then
                log debug "[EU] Ownership already $current for $path"
                continue
            fi
            if ! chown -R "$expected" "$path" 2>/dev/null; then
                log warn "[EU] chown failed for $path (wanted $expected)"
            fi
        fi
    done
}

# ---------------------------------------------------------------------
# enforce_dir_permissions()
# Apply chmod to directories only (recursively).
# Consumes: args: mode, paths; tools: find, chmod.
# Computes: chmod on directories.
# Returns: 0 always; logs warnings on failures.
# ---------------------------------------------------------------------
enforce_dir_permissions() {
    local mode="${1:-}"
    shift || true
    local paths=("$@")
    if [[ -z "$mode" || ${#paths[@]} -eq 0 ]]; then
        log debug "[EPD] Mode or paths missing; skipping dir chmod."
        return 0
    fi
    for path in "${paths[@]}"; do
        if [ -d "$path" ]; then
            if ! find "$path" -type d -exec chmod "$mode" {} + 2>/dev/null; then
                log warn "[EPD] chmod failed for $path (wanted $mode)"
            fi
        fi
    done
}

# ---------------------------------------------------------------------
# enforce_file_permissions()
# Apply chmod to files only (recursively), skipping executables.
# Consumes: args: mode, paths; tools: find, chmod.
# Computes: chmod on files without execute bits.
# Returns: 0 always; logs warnings on failures.
# ---------------------------------------------------------------------
enforce_file_permissions() {
    local mode="${1:-}"
    shift || true
    local paths=("$@")
    local had_fail=false
    if [[ -z "$mode" || ${#paths[@]} -eq 0 ]]; then
        log debug "[EPF] Mode or paths missing; skipping file chmod."
        return 0
    fi
    for path in "${paths[@]}"; do
        if [ -d "$path" ]; then
            if ! find "$path" -type f ! -perm -111 -exec chmod "$mode" {} + 2>/dev/null; then
                log warn "[EPF] chmod failed for files in $path (wanted $mode)"
                had_fail=true
            fi
        elif [ -f "$path" ]; then
            if ! chmod "$mode" "$path" 2>/dev/null; then
                log warn "[EPF] chmod failed for $path (wanted $mode)"
                had_fail=true
            fi
        fi
    done
    if [[ "$had_fail" == true ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# enforce_file_mode()
# Apply chmod to specific files only.
# Consumes: args: mode, files; tools: chmod.
# Computes: chmod on file list.
# Returns: 0 always; logs warnings on failures.
# ---------------------------------------------------------------------
enforce_file_mode() {
    local mode="${1:-}"
    shift || true
    local files=("$@")
    local had_fail=false
    if [[ -z "$mode" || ${#files[@]} -eq 0 ]]; then
        log debug "[EPF] Mode or files missing; skipping file chmod."
        return 0
    fi
    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            local current_mode
            current_mode="$(_fs_get_mode "$file")"
            if [[ "$current_mode" == "$mode" ]]; then
                log debug "[EPF] Mode already $mode for $file"
                continue
            fi
            if ! chmod "$mode" "$file" 2>/dev/null; then
                log warn "[EPF] chmod failed for $file (wanted $mode)"
                had_fail=true
            fi
        fi
    done
    if [[ "$had_fail" == true ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# enforce_permissions()
# Apply chmod recursively to paths.
# Consumes: args: mode, paths; tools: chmod.
# Computes: chmod -R over paths.
# Returns: 0 always; logs warnings on failures.
# ---------------------------------------------------------------------
enforce_permissions() {
    local mode="${1:-}"
    shift || true
    local paths=("$@")
    if [[ -z "$mode" || ${#paths[@]} -eq 0 ]]; then
        log debug "[EP] Mode or paths missing; skipping chmod."
        return 0
    fi
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            local current_mode
            current_mode="$(_fs_get_mode "$path")"
            if [[ "$current_mode" == "$mode" ]]; then
                log debug "[EP] Mode already $mode for $path"
                continue
            fi
            if ! chmod -R "$mode" "$path" 2>/dev/null; then
                log warn "[EP] chmod failed for $path (wanted $mode)"
            fi
        fi
    done
}

# ---------------------------------------------------------------------
# fs_user_can_write()
# Check if a user has write access to a path based on owner/mode bits.
# Consumes: args: path, user, require_exec; deps: _fs_get_owner, _fs_get_mode, id.
# Computes: owner/group permission match (no ACL evaluation).
# Returns: 0 if write access is available, 1 otherwise.
# ---------------------------------------------------------------------
fs_user_can_write() {
    local path="$1"
    local user="${2:-}"
    local require_exec="${3:-false}"
    [ -z "$path" ] && return 1
    [ ! -e "$path" ] && return 1

    if [ -z "$user" ]; then
        user="$(id -un 2>/dev/null || true)"
    fi
    if [ -z "$user" ]; then
        return 1
    fi
    if ! id -u "$user" >/dev/null 2>&1; then
        user="$(id -un 2>/dev/null || true)"
    fi
    if [ "$user" = "root" ]; then
        return 0
    fi

    local owner_group owner group
    owner_group="$(_fs_get_owner "$path")"
    owner="${owner_group%%:*}"
    group="${owner_group#*:}"

    local mode mode_digits perm_u perm_g perm_o perm_check
    mode="$(_fs_get_mode "$path")"
    if [ -z "$mode" ]; then
        return 1
    fi
    mode_digits="${mode: -3}"
    perm_u="${mode_digits:0:1}"
    perm_g="${mode_digits:1:1}"
    perm_o="${mode_digits:2:1}"

    if [ -n "$owner" ] && [ "$user" = "$owner" ]; then
        perm_check="$perm_u"
    else
        if id -Gn "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
            perm_check="$perm_g"
        else
            perm_check="$perm_o"
        fi
    fi

    if (( (perm_check & 2) == 0 )); then
        return 1
    fi
    if [ "$require_exec" = true ] && (( (perm_check & 1) == 0 )); then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# fs_emit_result()
# Emit a permission check result via a reporter or fallback logging.
# Consumes: args: report_fn, status, tag, detail; deps: log.
# Computes: routed status message.
# Returns: 0 always.
# ---------------------------------------------------------------------
fs_emit_result() {
    local report_fn="$1"
    local status="$2"
    local tag="$3"
    local detail="$4"
    local safe_tag="${tag:-PERM}"
    if [[ -n "$report_fn" ]] && declare -F "$report_fn" >/dev/null 2>&1; then
        "$report_fn" "$status" "$safe_tag" "$detail"
        return 0
    fi
    case "$status" in
        OK) log info "[${safe_tag}] $detail" ;;
        WARN) log warn "[${safe_tag}] $detail" ;;
        ERR) log err "[${safe_tag}] $detail" ;;
        INFO) log info "[${safe_tag}] $detail" ;;
        *) log info "[${safe_tag}] $detail" ;;
    esac
}

# ---------------------------------------------------------------------
# fs_check_owner_and_fix()
# Verify ownership and optionally fix it.
# Consumes: args: path, expected_owner, fix_permissions, report_fn, tag; deps: _fs_get_owner, enforce_ownership.
# Computes: ownership status message.
# Returns: 0 after evaluation.
# ---------------------------------------------------------------------
fs_check_owner_and_fix() {
    local path="$1"
    local expected_owner="$2"
    local fix_permissions="$3"
    local report_fn="$4"
    local tag="$5"
    [ -z "$path" ] && return 0
    [ ! -e "$path" ] && return 0
    local owner
    owner="$(_fs_get_owner "$path")"
    if [ -n "$owner" ] && [ -n "$expected_owner" ] && [ "$owner" != "$expected_owner" ]; then
        if [ "$fix_permissions" = true ]; then
            if [ "$EUID" -eq 0 ]; then
                fs_emit_result "$report_fn" WARN "$tag" "Fixing ownership for $path (was $owner -> $expected_owner)"
                enforce_ownership "$path"
            else
                fs_emit_result "$report_fn" WARN "$tag" "Ownership mismatch at $path (owner=$owner, expected=$expected_owner). Run: sudo chown -R ${expected_owner} \"$path\""
            fi
        else
            fs_emit_result "$report_fn" WARN "$tag" "Ownership mismatch at $path (owner=$owner, expected=$expected_owner). Use --fix-permissions to repair."
        fi
    else
        fs_emit_result "$report_fn" OK "$tag" "$path owned by ${owner:-unknown}"
    fi
}

# ---------------------------------------------------------------------
# fs_check_dir_mode()
# Verify a directory mode and optionally fix it.
# Consumes: args: path, expected_mode, fix_permissions, report_fn, tag; deps: _fs_get_mode, enforce_dir_permissions.
# Computes: mode mismatch warnings.
# Returns: 0 after evaluation.
# ---------------------------------------------------------------------
fs_check_dir_mode() {
    local path="$1"
    local expected_mode="$2"
    local fix_permissions="$3"
    local report_fn="$4"
    local tag="$5"
    [ -z "$path" ] && return 0
    [ ! -d "$path" ] && return 0
    local current
    current="$(_fs_get_mode "$path")"
    if [ -n "$current" ] && [ -n "$expected_mode" ] && [ "$current" != "$expected_mode" ]; then
        if [ "$fix_permissions" = true ]; then
            fs_emit_result "$report_fn" WARN "$tag" "Fixing dir mode for $path (was $current -> $expected_mode)"
            enforce_dir_permissions "$expected_mode" "$path"
        else
            fs_emit_result "$report_fn" WARN "$tag" "Dir mode mismatch at $path (mode=$current, expected=$expected_mode). Use --fix-permissions to repair."
        fi
    fi
}

# ---------------------------------------------------------------------
# fs_check_file_mode()
# Verify a file mode and optionally fix it.
# Consumes: args: path, expected_mode, fix_permissions, label, report_fn, tag; deps: _fs_get_mode, enforce_file_mode.
# Computes: mode mismatch warnings.
# Returns: 0 after evaluation.
# ---------------------------------------------------------------------
fs_check_file_mode() {
    local path="$1"
    local expected_mode="$2"
    local fix_permissions="$3"
    local label="$4"
    local report_fn="$5"
    local tag="$6"
    [ -z "$path" ] && return 0
    [ ! -f "$path" ] && return 0
    local current
    current="$(_fs_get_mode "$path")"
    local safe_label="${label:-file}"
    if [ -n "$current" ] && [ -n "$expected_mode" ] && [ "$current" != "$expected_mode" ]; then
        if [ "$fix_permissions" = true ]; then
            if enforce_file_mode "$expected_mode" "$path"; then
                local updated_mode
                updated_mode="$(_fs_get_mode "$path")"
                if [[ -n "$updated_mode" && "$updated_mode" == "$expected_mode" ]]; then
                    fs_emit_result "$report_fn" OK "$tag" "Fixed ${safe_label} mode (was $current -> $expected_mode)"
                else
                    fs_emit_result "$report_fn" WARN "$tag" "${safe_label} mode still mismatched (now=$updated_mode, expected=$expected_mode). Run as root or use --override-enforced-user."
                fi
            else
                fs_emit_result "$report_fn" WARN "$tag" "${safe_label} mode fix failed (permission denied). Run as root or use --override-enforced-user."
            fi
        else
            fs_emit_result "$report_fn" WARN "$tag" "${safe_label} mode mismatch (mode=$current, expected=$expected_mode). Use --fix-permissions to repair."
        fi
    fi
}

# ---------------------------------------------------------------------
# fs_emit_permissions_preflight()
# Emit ownership and permission checks for preflight output.
# Consumes: args: add_fn, enforced_user, fix_permissions, app_dir; env: INM_*; deps: fs_check_owner_and_fix/fs_check_dir_mode/fs_check_file_mode/enforce_file_permissions/_fs_get_mode/expand_path_vars.
# Computes: PERM status lines and optional fixes.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
fs_emit_permissions_preflight() {
    local add_fn="$1"
    local enforced_user="$2"
    local fix_permissions="${3:-false}"
    local app_dir="${4:-${INM_INSTALLATION_PATH%/}}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    perm_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "PERM" "$detail"
        else
            case "$status" in
                OK) log info "[PERM] $detail" ;;
                WARN) log warn "[PERM] $detail" ;;
                ERR) log err "[PERM] $detail" ;;
                INFO) log info "[PERM] $detail" ;;
                *) log info "[PERM] $detail" ;;
            esac
        fi
    }

    if [ -z "$enforced_user" ]; then
        return 0
    fi

    local expected_group="${INM_ENFORCED_GROUP:-}"
    if [ -z "$expected_group" ]; then
        expected_group="$(id -gn "$enforced_user" 2>/dev/null || true)"
        [[ -z "$expected_group" ]] && expected_group="$enforced_user"
    fi
    local expected_owner="${enforced_user}:${expected_group}"
    local dir_mode="${INM_DIR_MODE:-2750}"
    local backup_dir_mode="${INM_BACKUP_DIR_MODE:-}"
    local file_mode="${INM_FILE_MODE:-640}"
    local env_mode="${INM_ENV_MODE:-600}"
    local cli_env_mode="${INM_CLI_ENV_MODE:-600}"
    if [[ -z "$backup_dir_mode" ]]; then
        backup_dir_mode="$dir_mode"
    fi
    local perm_paths=()
    local cli_env_path=""
    local backup_dir_path=""
    if [ -n "${INM_BASE_DIRECTORY:-}" ]; then
        perm_paths+=("${INM_BASE_DIRECTORY%/}")
    fi
    if [ -n "${INM_BACKUP_DIRECTORY:-}" ]; then
        backup_dir_path="$(expand_path_vars "$INM_BACKUP_DIRECTORY")"
        perm_paths+=("$backup_dir_path")
    fi
    if [ -n "${INM_CACHE_LOCAL_DIRECTORY:-}" ]; then
        perm_paths+=("$(expand_path_vars "$INM_CACHE_LOCAL_DIRECTORY")")
    fi
    if [ -n "${INM_CACHE_GLOBAL_DIRECTORY:-}" ]; then
        perm_paths+=("$(expand_path_vars "$INM_CACHE_GLOBAL_DIRECTORY")")
    fi
    if [ -n "${INM_HISTORY_LOG_FILE:-}" ]; then
        local hist_path
        hist_path="$(expand_path_vars "$INM_HISTORY_LOG_FILE")"
        if [ -n "$hist_path" ]; then
            perm_paths+=("$(dirname "$hist_path")")
            perm_paths+=("$hist_path")
        fi
    fi
    if [ -n "${INM_SELF_ENV_FILE:-}" ]; then
        cli_env_path="$(expand_path_vars "$INM_SELF_ENV_FILE")"
        if [ -n "$cli_env_path" ]; then
            perm_paths+=("$cli_env_path")
        fi
    fi
    if [ -n "$app_dir" ]; then
        perm_paths+=("$app_dir")
        perm_paths+=("${app_dir%/}/storage")
        perm_paths+=("${app_dir%/}/public")
    fi

    local p
    for p in "${perm_paths[@]}"; do
        fs_check_owner_and_fix "$p" "$expected_owner" "$fix_permissions" "$add_fn" "PERM"
    done

    if [ -n "$app_dir" ]; then
        fs_check_dir_mode "${app_dir%/}" "$dir_mode" "$fix_permissions" "$add_fn" "PERM"
        fs_check_dir_mode "${app_dir%/}/storage" "$dir_mode" "$fix_permissions" "$add_fn" "PERM"
        fs_check_dir_mode "${app_dir%/}/public" "$dir_mode" "$fix_permissions" "$add_fn" "PERM"
        fs_check_dir_mode "${app_dir%/}/bootstrap/cache" "$dir_mode" "$fix_permissions" "$add_fn" "PERM"

        local file_mode_applied=false
        if [ -f "${app_dir%/}/public/index.php" ]; then
            local current_file_mode
            current_file_mode="$(_fs_get_mode "${app_dir%/}/public/index.php")"
            if [ -n "$current_file_mode" ] && [ "$current_file_mode" != "$file_mode" ]; then
                if [ "$fix_permissions" = true ]; then
                    perm_emit WARN "Fixing file modes under app dir (target $file_mode)"
                    if ! enforce_file_permissions "$file_mode" "${app_dir%/}"; then
                        perm_emit WARN "File mode fix failed for ${app_dir%/} (permission denied). Run as root or use --override-enforced-user."
                    fi
                    file_mode_applied=true
                else
                    perm_emit WARN "File mode mismatch (public/index.php=$current_file_mode, expected=$file_mode). Use --fix-permissions to repair."
                fi
            fi
        fi
        if [ "$fix_permissions" = true ] && [ "$file_mode_applied" = false ]; then
            if ! enforce_file_permissions "$file_mode" "${app_dir%/}"; then
                perm_emit WARN "File mode fix failed for ${app_dir%/} (permission denied). Run as root or use --override-enforced-user."
            fi
        fi

        fs_check_file_mode "${app_dir%/}/.env" "$env_mode" "$fix_permissions" ".env" "$add_fn" "PERM"
    fi
    if [ -n "$backup_dir_path" ]; then
        fs_check_dir_mode "$backup_dir_path" "$backup_dir_mode" "$fix_permissions" "$add_fn" "PERM"
    fi
    fs_check_file_mode "$cli_env_path" "$cli_env_mode" "$fix_permissions" "CLI config" "$add_fn" "PERM"
}
