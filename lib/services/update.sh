#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_UPDATE_LOADED:-} ]] && return
__SERVICE_UPDATE_LOADED=1

# ---------------------------------------------------------------------
# run_update()
# Update Invoice Ninja to the latest or specified version.
# Consumes: args: version/cache_only/no_db_backup/etc; env: INM_*; deps: get_latest_version/download_ninja.
# Computes: download, backup, swap, post-update tasks, rollback markers.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
run_update() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping update."
        return 0
    fi
    local -A args=()
    parse_named_args args "$@"

    local show_changelog
    show_changelog="$(args_get args "false" show_changelog show-changelog)"
    local cache_only
    cache_only="$(args_get args "false" cache_only)"
    local no_db_backup
    no_db_backup="$(args_get args "false" no_db_backup)"
    local installed_version latest_version timestamp source_dir
    timestamp="$(date +'%Y%m%d_%H%M%S')"

    installed_version=$(get_installed_version)
    local version_arg
    version_arg="$(args_get args "" version)"
    latest_version="${version_arg:-$(get_latest_version)}"
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        local cache_dir
        cache_dir="$(resolve_cache_directory)"
        local cached_ver
        cached_ver="$(find "$cache_dir" -maxdepth 1 -type f -name 'invoiceninja_v*.tar.gz' 2>/dev/null \
            | sed -n 's|.*invoiceninja_v\\(.*\\)\\.tar\\.gz|\\1|p' | sort -V | tail -n1)"
        if [[ -n "$cached_ver" && -z "$version_arg" ]]; then
            log warn "[UPD] Latest version could not be determined. Cached package found: $cached_ver"
            if prompt_confirm "UPD_CACHE" "no" "[UPD] Use cached version $cached_ver? (yes/no):" false 30; then
                latest_version="$cached_ver"
            else
                log err "[UPD] Aborting update (no latest version and cached version declined)."
                return 1
            fi
        else
            log err "[UPD] Aborting update; no latest version and no cached fallback."
            return 1
        fi
    fi
    log info "[UPD] Installed: ${installed_version:-<unknown>} | Latest: ${latest_version:-<unknown>}"
    emit_changelog_link "UPD" "$installed_version" "$latest_version" "$show_changelog"

    # Cache-only path: download + checksum, no install/extract
    if args_is_true "$cache_only"; then
        log info "[UPD] Cache-only requested; downloading package without install."
        local cache_dir
        cache_dir="$(download_ninja "$latest_version")" || {
            log err "[UPD] Download failed."
            return 1
        }
        log ok "[UPD] Cached Invoice Ninja ${latest_version} at $cache_dir"
        return 0
    fi

    # expand any placeholders in INM_PATH_APP_ENV_FILE before use (without eval)
    # shellcheck disable=SC2016
    if printf '%s' "${INM_PATH_APP_ENV_FILE:-}" | grep -q '\${'; then
        INM_PATH_APP_ENV_FILE="$(expand_placeholders "$INM_PATH_APP_ENV_FILE")"
    fi
    if [ ! -f "$INM_PATH_APP_ENV_FILE" ]; then
        log warn "[UPD] No .env file found – the system is not provisioned or broken."
        log debug "[UPD] Please check the .env file location at $INM_PATH_APP_ENV_FILE"
        log info "[UPD] Use 'inm spawn provision-file' to set up a new system fast, use '-h' to see more options, or move a valid .env file into '$INM_PATH_APP_DIR' to fix a potentially broken installation."
        return 1
    fi

    if version_compare "$installed_version" gt "$latest_version"; then
        log warn "[UPD] You are attempting a downgrade: $installed_version → $latest_version"
    # shellcheck disable=SC2154
        if [ "$force_update" != true ]; then
            if ! prompt_confirm "UPD_DOWNGRADE" "no" "[UPD] Proceed? Type 'yes' to continue:" false 60; then
                log info "[UPD] Downgrade aborted."
                return 1
            fi
        else
            log debug "[UPD] Force flag set. Proceeding with downgrade."
        fi
    elif [[ "$installed_version" == "$latest_version" && "$force_update" != true ]]; then
        if ! prompt_confirm "UPD_REPEAT" "no" "[UPD] Version $installed_version is already current. Proceed anyway? (yes/no):" false 60; then
            log info "[UPD] Update cancelled by user."
            return 0
        fi
    fi

    run_hook "pre-update" || return 1

    if ! args_is_true "$no_db_backup"; then
        local backup_dir="${INM_BACKUP_DIR%/}"
        if [[ "$backup_dir" != /* ]]; then
            backup_dir="${INM_PATH_BASE_DIR%/}/${backup_dir#/}"
        fi
        mkdir -p "$backup_dir" 2>/dev/null || {
            log err "[UPD] Cannot create backup directory: $backup_dir"
            return 1
        }
        local install_name
        install_name="$(basename "${INM_INSTALLATION_PATH%/}")"
        local rollback_tag="${install_name}_rollback_${timestamp}"
        local db_backup="${backup_dir%/}/${rollback_tag}_db.sql"
        log info "[UPD] Creating mandatory DB backup: $db_backup"
        if ! INM_QUIET_DUMP=true dump_database "$db_backup"; then
            log err "[UPD] DB backup failed; aborting update. Use --no-db-backup to override (not recommended)."
            return 1
        fi
        enforce_ownership "$backup_dir"
    else
        log warn "[UPD] DB backup skipped by flag (--no-db-backup)."
    fi

    log info "[UPD] Fetching Invoice Ninja $latest_version"

    local cache_dir
    cache_dir="$(download_ninja "$latest_version")" || {
        log err "[UPD] Download failed."
        return 1
    }
    # Extract from cache tarball
    local extracted
    extracted="$(mktemp -d)"
    if ! INM_SPINNER_HEARTBEAT=0 spinner_run_mode normal "Extracting Invoice Ninja..." tar_extract_fallback "$cache_dir/invoiceninja_v$latest_version.tar.gz" "$extracted"; then
        log err "[UPD] Failed to extract Invoice Ninja archive."
        return 1
    fi
    source_dir="$(fs_resolve_single_root_dir "$extracted")"

    chmod -R u+rwX,go+rX "$source_dir" 2>/dev/null || true

    local install_path="${INM_INSTALLATION_PATH%/}"
    local install_parent
    install_parent="$(dirname "$install_path")"
    local install_name
    install_name="$(basename "$install_path")"
    local new_dir="${install_parent}/${install_name}_$latest_version"

    log debug "[UPD] Preparing new version directory: $new_dir"

    log debug "[UPD] Moving from extracted cache to $new_dir"
    if ! fs_stage_dir "$source_dir" "$new_dir" "$install_parent" move; then
        log err "[UPD] Failed to move/copy files to new directory"
        return 1
    fi

    log debug "[UPD] Copying .env to $new_dir"
    cp "$INM_PATH_APP_ENV_FILE" "$new_dir/.env" || {
        log err "[UPD] Failed to copy .env"
        return 1
    }

    local preserve_raw="${args[preserve_paths]:-${args[preserve-paths]:-${INM_UPDATE_PRESERVE_PATHS:-}}}"
    local preserve_paths=()
    app_default_preserve_paths preserve_paths
    if [[ -n "$preserve_raw" ]]; then
        IFS=',' read -ra preserve_extra <<<"$preserve_raw"
        preserve_paths+=("${preserve_extra[@]}")
    fi
    if [[ ${#preserve_paths[@]} -gt 0 ]]; then
        log debug "[UPD] Preserving custom paths from existing install"
        for p in "${preserve_paths[@]}"; do
            [[ -n "$p" ]] && app_preserve_path "UPD" "$install_path" "$new_dir" "$p"
        done
    fi

    log debug "[UPD] Moving previous installation to rollback directory"
    local rollback_dir="${install_parent}/${install_name}_rollback_${timestamp}"
    if [ -d "$install_path" ]; then
        safe_move_or_copy_and_clean "$install_path" "$rollback_dir" move || {
            log err "[UPD] Could not move current installation to rollback."
            return 1
        }
    fi

    log info "[UPD] Activating new version"
    safe_move_or_copy_and_clean "$new_dir" "$install_path" move || {
        log err "[UPD] Failed to activate new version."
        return 1
    }
    enforce_ownership "$install_path"
    if [[ -n "${INM_PERM_DIR_MODE:-}" ]]; then
        enforce_dir_permissions "$INM_PERM_DIR_MODE" "$install_path"
    fi
    if [[ -n "${INM_PERM_FILE_MODE:-}" ]]; then
        enforce_file_permissions "$INM_PERM_FILE_MODE" "$install_path"
    fi
    if [[ -n "${INM_PERM_APP_ENV_MODE:-}" ]]; then
        enforce_file_mode "$INM_PERM_APP_ENV_MODE" "${install_path%/}/.env"
    fi

    log info "[UPD] Running post-activation artisan tasks"
    if [[ "${DEBUG:-false}" == true || "${args[debug]:-false}" == true ]]; then
        run_artisan migrate --force || log warn "[UPD] artisan migrate failed"
        run_artisan optimize || log warn "[UPD] artisan optimize failed"
        run_artisan ninja:post-update || log warn "[UPD] artisan post-update failed"
        run_artisan ninja:check-data || log warn "[UPD] artisan check-data failed"
        run_artisan ninja:translations || log warn "[UPD] artisan translations failed"
        run_artisan ninja:design-update || log warn "[UPD] artisan design-update failed"
        run_artisan up || log warn "[UPD] artisan up failed"
    else
        run_artisan migrate --force >/dev/null 2>&1 || log warn "[UPD] artisan migrate failed"
        run_artisan optimize >/dev/null 2>&1 || log warn "[UPD] artisan optimize failed"
        run_artisan ninja:post-update >/dev/null 2>&1 || log warn "[UPD] artisan post-update failed"
        run_artisan ninja:check-data >/dev/null 2>&1 || log warn "[UPD] artisan check-data failed"
        run_artisan ninja:translations >/dev/null 2>&1 || log warn "[UPD] artisan translations failed"
        run_artisan ninja:design-update >/dev/null 2>&1 || log warn "[UPD] artisan design-update failed"
        run_artisan up >/dev/null 2>&1 || log warn "[UPD] artisan up failed"
    fi

    do_snappdf || log warn "[UPD] Snappdf setup failed"
    cleanup || log warn "[UPD] Cache cleanup failed"
    log ok "[UPD] Update completed successfully!"
    if [ -n "$rollback_dir" ]; then
        app_log_rollback_hint "UPD" "update" "$rollback_dir"
    fi
    if declare -F update_notice_clear >/dev/null 2>&1; then
        update_notice_clear "app"
    fi
    if declare -F update_notice_mark_checked >/dev/null 2>&1; then
        update_notice_mark_checked
    fi

    run_hook "post-update" || return 1
}

# ---------------------------------------------------------------------
# run_update_rollback()
# Rolls back to a previous version directory.
# Usage: inmanage core update rollback last|<dir>
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# run_update_rollback()
# Roll back to the previous update snapshot.
# Consumes: args: selection; env: INM_INSTALLATION_PATH.
# Computes: app directory swap to rollback version.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
run_update_rollback() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping rollback."
        return 0
    fi
    local -A args=()
    parse_named_args args "$@"
    local target
    target="$(app_parse_rollback_target args "latest" "$@")"

    local install_path="${INM_INSTALLATION_PATH%/}"
    local force
    force="$(args_get args "false" force)"
    app_run_rollback "UPD" "UPD_ROLLBACK" "$install_path" "$target" "$force"
}
