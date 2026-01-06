#!/usr/bin/env bash

# ---------------------------------------------------------------------
# app_sanity_items()
# Build missing/warn item lists for an app directory.
# Consumes: args: dir; deps: none.
# Computes: missing_ref, warn_ref arrays by checking paths.
# Returns: 0 if dir exists, 1 if invalid dir.
# ---------------------------------------------------------------------
app_sanity_items() {
    local dir="$1"
    local -n missing_ref="$2"
    local -n warn_ref="$3"

    missing_ref=()
    warn_ref=()
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        return 1
    fi

    [[ -f "${dir%/}/artisan" ]] || missing_ref+=("artisan")
    [[ -f "${dir%/}/vendor/autoload.php" ]] || missing_ref+=("vendor/autoload.php")
    [[ -f "${dir%/}/public/index.php" ]] || missing_ref+=("public/index.php")
    [[ -f "${dir%/}/.env" ]] || missing_ref+=(".env")
    [[ -d "${dir%/}/storage" ]] || missing_ref+=("storage/")
    [[ -d "${dir%/}/public" ]] || missing_ref+=("public/")
    [[ -d "${dir%/}/routes" ]] || warn_ref+=("routes/")
    [[ -d "${dir%/}/resources/views" ]] || warn_ref+=("resources/views/")
    [[ -d "${dir%/}/database" ]] || warn_ref+=("database/")
    [[ -f "${dir%/}/public/.htaccess" ]] || warn_ref+=("public/.htaccess")
    [[ -d "${dir%/}/bootstrap/cache" ]] || warn_ref+=("bootstrap/cache/")
    [[ -f "${dir%/}/composer.json" ]] || warn_ref+=("composer.json")
    [[ -f "${dir%/}/VERSION.txt" ]] || warn_ref+=("VERSION.txt")
    return 0
}

# ---------------------------------------------------------------------
# app_sanity_check()
# Validate app structure and log missing items.
# Consumes: args: dir; deps: app_sanity_items, fs_path_size.
# Computes: logs critical/non-critical findings.
# Returns: 0 if critical items present, 1 otherwise.
# ---------------------------------------------------------------------
app_sanity_check() {
    local dir="$1"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        log err "[ASC] App directory not found: ${dir:-<unset>}"
        return 1
    fi

    local missing=()
    local warn=()
    app_sanity_items "$dir" missing warn || return 1

    local sz
    sz="$(fs_path_size "$dir")"
    [[ -n "$sz" ]] && log info "[ASC] App footprint: $sz at $dir"

    if [[ ${#missing[@]} -gt 0 ]]; then
        log err "[ASC] Critical app items missing: ${missing[*]}"
        return 1
    fi

    if [[ ${#warn[@]} -gt 0 ]]; then
        log warn "[ASC] Non-critical items missing: ${warn[*]}"
    else
        log ok "[ASC] App structure looks complete."
    fi
    return 0
}

# ---------------------------------------------------------------------
# app_emit_preflight()
# Emit app sanity, URL, and update status for preflight output.
# Consumes: args: add_fn, app_dir, config_hint, fast, skip_github; env: APP_URL; deps: app_sanity_items/http_status/get_installed_version/get_latest_version/version_compare/gh_release_list_versions.
# Computes: app structure and update status lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
app_emit_preflight() {
    local add_fn="$1"
    local app_dir="$2"
    local config_hint="$3"
    local fast="${4:-false}"
    local skip_github="${5:-false}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    app_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "APP" "$detail"
        else
            case "$status" in
                OK) log info "[APP] $detail" ;;
                WARN) log warn "[APP] $detail" ;;
                ERR) log err "[APP] $detail" ;;
                INFO) log info "[APP] $detail" ;;
                *) log info "[APP] $detail" ;;
            esac
        fi
    }

    if [[ -z "$app_dir" || ! -d "$app_dir" ]]; then
        return 0
    fi

    local app_missing=()
    local app_warn=()
    app_sanity_items "$app_dir" app_missing app_warn || true

    if [[ ${#app_missing[@]} -gt 0 ]]; then
        app_emit ERR "Critical app items missing: ${app_missing[*]}"
        if [ -n "$config_hint" ]; then
            app_emit WARN "Config found (${config_hint}) but app tree is missing/incomplete. Fix: move existing app to ${app_dir} or run 'inm core install --provision' (recommended). For guidance, run 'inm core install --help'."
        fi
    else
        app_emit OK "App structure looks complete at ${app_dir}"
        if [[ ${#app_warn[@]} -gt 0 ]]; then
            app_emit WARN "Non-critical items missing: ${app_warn[*]}"
        fi
    fi

    if [ -n "${APP_URL:-}" ]; then
        local app_url_trim status_code
        app_url_trim="${APP_URL%/}"
        status_code="$(http_status "$app_url_trim")"
        if [[ "$status_code" == "200" ]]; then
            app_emit OK "APP_URL returns 200 OK (${app_url_trim})"
        elif [[ "$status_code" =~ ^3 ]]; then
            app_emit WARN "APP_URL redirects (HTTP ${status_code}): ${app_url_trim}"
        elif [[ "$status_code" == "000" ]]; then
            app_emit WARN "APP_URL not reachable (no HTTP response): ${app_url_trim}"
        else
            app_emit ERR "APP_URL returned HTTP ${status_code}: ${app_url_trim}"
        fi
    fi

    if [ "$fast" != true ] && [ "$skip_github" != true ]; then
        local app_installed_version=""
        app_installed_version="$(get_installed_version 2>/dev/null || true)"
        if [ -n "$app_installed_version" ]; then
            local app_latest_version=""
            app_latest_version="$(get_latest_version 2>/dev/null || true)"
            if [ -n "$app_latest_version" ] && [ "$app_latest_version" != "null" ]; then
                local app_installed_tag="${app_installed_version#v}"
                local app_latest_tag="${app_latest_version#v}"
                if version_compare "$app_installed_tag" lt "$app_latest_tag"; then
                    local update_level="INFO"
                    local releases_behind="" release_count_line=""
                    local compare_url="https://github.com/invoiceninja/invoiceninja/compare/v${app_installed_tag}...v${app_latest_tag}"
                    local releases=""
                    releases="$(gh_release_list_versions "invoiceninja/invoiceninja" "v" 100 2>/dev/null || true)"
                    if [ -n "$releases" ]; then
                        local idx=0 tag
                        while IFS= read -r tag; do
                            if [ "$tag" = "$app_installed_tag" ]; then
                                releases_behind="$idx"
                                break
                            fi
                            idx=$((idx + 1))
                        done <<< "$releases"
                    fi
                    if [[ "$releases_behind" =~ ^[0-9]+$ ]]; then
                        if [ "$releases_behind" -ge 10 ]; then
                            update_level="ERR"
                        elif [ "$releases_behind" -ge 5 ]; then
                            update_level="WARN"
                        fi
                        release_count_line=" (${releases_behind} releases behind)"
                    fi
                    app_emit "$update_level" "Update available: ${app_installed_tag} -> ${app_latest_tag}${release_count_line} (run: inm core update)"
                    app_emit INFO "Changelog: ${compare_url}"
                else
                    app_emit OK "App up to date (${app_installed_tag})"
                fi
            else
                app_emit INFO "Update check skipped (latest version unavailable)"
            fi
        else
            app_emit INFO "Update check skipped (VERSION.txt missing)"
        fi
    else
        app_emit INFO "Update check skipped (--skip-github/--fast)"
    fi
}

# ---------------------------------------------------------------------
# app_run_rollback_in_dir()
# Switch current install with a rollback directory under a given root.
# Consumes: args: tag, prompt_key, install_path, rollback_root, prefix, target, force;
#          deps: safe_move_or_copy_and_clean, prompt_confirm.
# Computes: moves current install to new rollback and restores target.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
app_run_rollback_in_dir() {
    local tag="$1"
    local prompt_key="$2"
    local install_path="$3"
    local rollback_root="$4"
    local prefix="$5"
    local target="$6"
    local force="$7"

    install_path="${install_path%/}"
    rollback_root="${rollback_root%/}"

    if [[ -z "$install_path" || ! -d "$(dirname "$install_path")" ]]; then
        log err "[${tag}] Install path not set or invalid: ${install_path:-<unset>}"
        return 1
    fi
    if [[ ! -d "$install_path" ]]; then
        log err "[${tag}] Current installation not found at $install_path"
        return 1
    fi
    if [[ -z "$rollback_root" || ! -d "$rollback_root" ]]; then
        log err "[${tag}] Rollback root not found: ${rollback_root:-<unset>}"
        return 1
    fi

    local rollback_dir=""
    if [[ "$target" == "latest" || "$target" == "last" ]]; then
        rollback_dir="$(find "$rollback_root" -maxdepth 1 -type d -name "${prefix}*" 2>/dev/null | sort -r | head -n1)"
        if [[ -z "$rollback_dir" ]]; then
            log err "[${tag}] No rollback directory found in $rollback_root"
            return 1
        fi
    else
        if [[ -d "$target" ]]; then
            rollback_dir="$target"
        elif [[ -d "${rollback_root%/}/$target" ]]; then
            rollback_dir="${rollback_root%/}/$target"
        else
            log err "[${tag}] Rollback directory not found: $target"
            return 1
        fi
    fi

    local rollback_name
    rollback_name="$(basename "$rollback_dir")"

    if ! args_is_true "$force"; then
        if ! prompt_confirm "$prompt_key" "no" "Rollback to ${rollback_name}? (yes/no):" false 60; then
            log info "[${tag}] Rollback cancelled."
            return 0
        fi
    else
        log info "[${tag}] Force flag set. Proceeding with rollback."
    fi

    local timestamp
    timestamp="$(date +'%Y%m%d_%H%M%S')"
    local new_rollback="${rollback_root}/${prefix}${timestamp}"

    log info "[${tag}] Moving current install to rollback: $(basename "$new_rollback")"
    safe_move_or_copy_and_clean "$install_path" "$new_rollback" move || {
        log err "[${tag}] Failed to move current installation to rollback."
        return 1
    }

    log info "[${tag}] Restoring rollback: ${rollback_name}"
    safe_move_or_copy_and_clean "$rollback_dir" "$install_path" move || {
        log err "[${tag}] Failed to restore rollback directory."
        return 1
    }
    enforce_ownership "$install_path"
    log ok "[${tag}] Rollback activated: ${rollback_name}"
    return 0
}

# ---------------------------------------------------------------------
# app_run_rollback()
# Switch current install with a rollback directory.
# Consumes: args: tag, prompt_key, install_path, target, force; deps: app_run_rollback_in_dir.
# Computes: rollback with standard install rollback prefix.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
app_run_rollback() {
    local tag="$1"
    local prompt_key="$2"
    local install_path="$3"
    local target="$4"
    local force="$5"
    local install_parent install_name

    install_path="${install_path%/}"
    install_parent="$(dirname "$install_path")"
    install_name="$(basename "$install_path")"

    app_run_rollback_in_dir "$tag" "$prompt_key" "$install_path" "$install_parent" "${install_name}_rollback_" "$target" "$force"
}

# ---------------------------------------------------------------------
# app_parse_rollback_target()
# Resolve rollback target from named args or positional args.
# Consumes: args: assoc array name, default_target, argv; deps: args_get/args_is_true.
# Computes: rollback target string.
# Returns: prints target to stdout.
# ---------------------------------------------------------------------
app_parse_rollback_target() {
    local -n args_ref="$1"
    local default_target="$2"
    shift 2 || true
    local target
    target="$(args_get args_ref "" target rollback dir)"
    local name
    name="$(args_get args_ref "" name)"
    local latest
    latest="$(args_get args_ref "false" latest)"
    if [[ -n "$name" ]]; then
        target="$name"
    fi
    if args_is_true "$latest"; then
        target="$default_target"
    fi
    if [[ -z "$target" ]]; then
        local arg
        for arg in "$@"; do
            if [[ "$arg" != --* ]]; then
                target="$arg"
                break
            fi
        done
    fi
    target="${target:-$default_target}"
    printf "%s" "$target"
}

# ---------------------------------------------------------------------
# app_build_rollback_hint()
# Build rollback name + command for a given action.
# Consumes: args: action, rollback_dir, cli_cmd, out_name_var, out_cmd_var.
# Computes: rollback name + command string.
# Returns: 0 after setting output vars.
# ---------------------------------------------------------------------
app_build_rollback_hint() {
    local action="$1"
    local rollback_dir="$2"
    local cli_cmd="${3:-inm}"
    local name_var="$4"
    local cmd_var="$5"
    local rollback_name_val rollback_cmd_val
    rollback_name_val="$(basename "$rollback_dir")"
    rollback_cmd_val="${cli_cmd} core ${action} rollback --latest (or: --name=${rollback_name_val})"
    printf -v "$name_var" "%s" "$rollback_name_val"
    printf -v "$cmd_var" "%s" "$rollback_cmd_val"
}

# ---------------------------------------------------------------------
# app_log_rollback_hint()
# Emit rollback hint logs for an action.
# Consumes: args: tag, action, rollback_dir; deps: app_build_rollback_hint, log.
# Computes: standardized rollback info lines.
# Returns: 0 after logging.
# ---------------------------------------------------------------------
app_log_rollback_hint() {
    local tag="$1"
    local action="$2"
    local rollback_dir="$3"
    local rollback_name rollback_cmd
    app_build_rollback_hint "$action" "$rollback_dir" "inm" rollback_name rollback_cmd
    log info "[${tag}] Rollback available: ${rollback_name}"
    log info "[${tag}] Rollback: ${rollback_cmd}"
}

# ---------------------------------------------------------------------
# app_preserve_path()
# Copy a path from current app into a new target tree if missing.
# Consumes: args: tag, src_root, dst_root, rel; tools: rsync/cp.
# Computes: copies directory or file if it exists.
# Returns: 0 always (logs warn on failures).
# ---------------------------------------------------------------------
app_preserve_path() {
    local tag="$1"
    local src_root="$2"
    local dst_root="$3"
    local rel="$4"
    rel="${rel#/}"
    local src="${src_root%/}/$rel"
    local dst="${dst_root%/}/$rel"
    if [[ -d "$src" ]]; then
        if ! fs_sync_dir "$tag preserve" "$src" "$dst" false normal "$tag" --ignore-existing; then
            log warn "[${tag}] Failed to preserve directory: $rel"
        fi
        return 0
    fi
    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$dst")" 2>/dev/null || true
        if [[ ! -e "$dst" ]]; then
            cp -a "$src" "$dst" || log warn "[${tag}] Failed to preserve file: $rel"
        fi
        return 0
    fi
    log debug "[${tag}] Preserve path not found: $rel"
    return 0
}
