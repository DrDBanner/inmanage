#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_UPDATE_LOADED:-} ]] && return
__SERVICE_UPDATE_LOADED=1

# ---------------------------------------------------------------------
# run_update()
# Updates Invoice Ninja to the latest available or specified version.
# ---------------------------------------------------------------------
run_update() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping update."
        return 0
    fi
    local -A args=()
    parse_named_args args "$@"

    local cache_only="${args[cache_only]:-${args[cache-only]:-false}}"
    local no_db_backup="${args[no_db_backup]:-${args[no-db-backup]:-false}}"
    local installed_version latest_version timestamp response source_dir
    timestamp="$(date +'%Y%m%d_%H%M%S')"

    installed_version=$(get_installed_version)
    latest_version="${args[version]:-$(get_latest_version)}"
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        local cache_dir
        cache_dir="$(resolve_cache_directory)"
        local cached_ver
        cached_ver="$(find "$cache_dir" -maxdepth 1 -type f -name 'invoiceninja_v*.tar.gz' 2>/dev/null \
            | sed -n 's|.*invoiceninja_v\\(.*\\)\\.tar\\.gz|\\1|p' | sort -V | tail -n1)"
        if [[ -n "$cached_ver" && -z "${args[version]:-}" ]]; then
            log warn "[UPD] Latest version could not be determined. Cached package found: $cached_ver"
            log info "[UPD] Use cached version $cached_ver? (y/N):"
            read -r -t 30 response || response=""
            if [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
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

    # Cache-only path: download + checksum, no install/extract
    if [[ "$cache_only" == true ]]; then
        log info "[UPD] Cache-only requested; downloading package without install."
        local cache_dir
        cache_dir="$(download_ninja "$latest_version")" || {
            log err "[UPD] Download failed."
            return 1
        }
        log ok "[UPD] Cached Invoice Ninja ${latest_version} at $cache_dir"
        return 0
    fi

    # expand any placeholders in INM_ENV_FILE before use (without eval)
    if [[ "${INM_ENV_FILE:-}" == *\${* ]] && declare -F expand_placeholders >/dev/null; then
        INM_ENV_FILE="$(expand_placeholders "$INM_ENV_FILE")"
    fi
    if [ ! -f "$INM_ENV_FILE" ]; then
        log warn "[UPD] No .env file found – the system is not provisioned or broken."
        log debug "[UPD] Please check the .env file location at $INM_ENV_FILE"
        log info "[UPD] Use 'spawn_provision' to set up a new system fast, use '-h' to see more options, or move a valid .env file into '$INM_INSTALLATION_DIRECTORY' to fix a potentially broken installation."
        return 1
    fi

    if version_compare "$installed_version" gt "$latest_version"; then
        log warn "[UPD] You are attempting a downgrade: $installed_version → $latest_version"
    # shellcheck disable=SC2154
    if [ "$force_update" != true ]; then
            log warn "[UPD] Proceed? Type 'yes' to continue:"
            read -r confirm
            [[ "$confirm" != "yes" ]] && {
                log info "[UPD] Downgrade aborted."
                return 1
            }
        else
            log info "[UPD] Force flag set. Proceeding with downgrade."
        fi
    elif [[ "$installed_version" == "$latest_version" && "$force_update" != true ]]; then
        log info "[UPD] Version $installed_version is already current. Proceed anyway? (yes/no):"
        read -r -t 60 response || {
            log warn "[UPD] No response. Update aborted."
            return 0
        }
        [[ ! "$response" =~ ^([Yy]([Ee][Ss])?)$ ]] && {
            log info "[UPD] Update cancelled by user."
            return 0
        }
    fi

    if declare -F run_hook >/dev/null 2>&1; then
        run_hook "pre-update" || return 1
    fi

    if [[ "$no_db_backup" != "true" ]]; then
        local backup_dir="${INM_BACKUP_DIRECTORY%/}"
        if [[ "$backup_dir" != /* ]]; then
            backup_dir="${INM_BASE_DIRECTORY%/}/${backup_dir#/}"
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
        if ! dump_database "$db_backup"; then
            log err "[UPD] DB backup failed; aborting update. Use --no-db-backup to override (not recommended)."
            return 1
        fi
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
    if declare -F tar_safe_extract >/dev/null 2>&1; then
        if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Extracting Invoice Ninja..." tar_safe_extract "$cache_dir/invoiceninja_v$latest_version.tar.gz" "$extracted"; then
            log err "[UPD] Failed to extract Invoice Ninja archive."
            return 1
        fi
    elif ! INM_SPINNER_HEARTBEAT=0 spinner_run "Extracting Invoice Ninja..." tar -xzf "$cache_dir/invoiceninja_v$latest_version.tar.gz" -C "$extracted"; then
        log err "[UPD] Failed to extract Invoice Ninja archive."
        return 1
    fi
    source_dir="$extracted"
    # If archive contains a single top-level directory, use it as the source root
    mapfile -t top_entries < <(find "$extracted" -mindepth 1 -maxdepth 1 -print)
    if [[ ${#top_entries[@]} -eq 1 && -d "${top_entries[0]}" ]]; then
        source_dir="${top_entries[0]}"
    fi

    chmod -R u+rwX,go+rX "$source_dir" 2>/dev/null || true

    local install_path="${INM_INSTALLATION_PATH%/}"
    local install_parent
    install_parent="$(dirname "$install_path")"
    local install_name
    install_name="$(basename "$install_path")"
    local new_dir="${install_parent}/${install_name}_$latest_version"

    log info "[UPD] Preparing new version directory: $new_dir"

    safe_rm_rf "$new_dir" "$install_parent"
    mkdir -p "$(dirname "$new_dir")"

    log info "[UPD] Moving from extracted cache to $new_dir"
    safe_move_or_copy_and_clean "$source_dir" "$new_dir" move || {
        log err "[UPD] Failed to move/copy files to new directory"
        return 1
    }

    log info "[UPD] Copying .env to $new_dir"
    cp "$INM_ENV_FILE" "$new_dir/.env" || {
        log err "[UPD] Failed to copy .env"
        return 1
    }

    preserve_update_path() {
        local rel="$1"
        rel="${rel#/}"
        local src="${install_path%/}/$rel"
        local dst="${new_dir%/}/$rel"
        if [[ -d "$src" ]]; then
            mkdir -p "$dst" 2>/dev/null || true
            rsync -a --ignore-existing "$src/." "$dst/" || \
                log warn "[UPD] Failed to preserve directory: $rel"
            return 0
        fi
        if [[ -f "$src" ]]; then
            mkdir -p "$(dirname "$dst")" 2>/dev/null || true
            if [[ ! -e "$dst" ]]; then
                cp -a "$src" "$dst" || log warn "[UPD] Failed to preserve file: $rel"
            fi
            return 0
        fi
        log debug "[UPD] Preserve path not found: $rel"
        return 0
    }

    local preserve_paths_default=("storage" "public/uploads" "public/.user.ini" "public/.well-known")
    local preserve_raw="${args[preserve_paths]:-${args[preserve-paths]:-${INM_PRESERVE_PATHS:-}}}"
    local preserve_paths=("${preserve_paths_default[@]}")
    if [[ -n "$preserve_raw" ]]; then
        IFS=',' read -ra preserve_extra <<<"$preserve_raw"
        preserve_paths+=("${preserve_extra[@]}")
    fi
    if [[ ${#preserve_paths[@]} -gt 0 ]]; then
        log info "[UPD] Preserving custom paths from existing install"
        for p in "${preserve_paths[@]}"; do
            [[ -n "$p" ]] && preserve_update_path "$p"
        done
    fi

    log info "[UPD] Moving previous installation to rollback directory"
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

    log info "[UPD] Running post-activation artisan tasks"
    run_artisan migrate --force || log warn "[UPD] artisan migrate failed"
    run_artisan optimize || log warn "[UPD] artisan optimize failed"
    run_artisan ninja:post-update || log warn "[UPD] artisan post-update failed"
    run_artisan ninja:check-data || log warn "[UPD] artisan check-data failed"
    run_artisan ninja:translations || log warn "[UPD] artisan translations failed"
    run_artisan ninja:design-update || log warn "[UPD] artisan design-update failed"
    run_artisan up || log warn "[UPD] artisan up failed"

    do_snappdf || log warn "[UPD] Snappdf setup failed"
    cleanup || log warn "[UPD] Cache cleanup failed"
    log ok "[UPD] Update completed successfully!"
    if [ -n "$rollback_dir" ]; then
        log info "[UPD] Rollback available: $(basename "$rollback_dir")"
        log info "[UPD] Rollback: inm update rollback last (or: inm update rollback $(basename "$rollback_dir"))"
    fi

    if declare -F run_hook >/dev/null 2>&1; then
        run_hook "post-update" || return 1
    fi
}

# ---------------------------------------------------------------------
# run_update_rollback()
# Rolls back to a previous version directory.
# Usage: inmanage core update rollback last|<dir>
# ---------------------------------------------------------------------
run_update_rollback() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping rollback."
        return 0
    fi
    local -A args=()
    parse_named_args args "$@"
    local target="${args[target]:-${args[rollback]:-${args[dir]:-}}}"
    if [ -z "$target" ]; then
        for arg in "$@"; do
            if [[ "$arg" != --* ]]; then
                target="$arg"
                break
            fi
        done
    fi
    target="${target:-last}"

    local install_path="${INM_INSTALLATION_PATH%/}"
    local install_parent install_name
    install_parent="$(dirname "$install_path")"
    install_name="$(basename "$install_path")"

    if [ -z "$install_path" ] || [ ! -d "$install_parent" ]; then
        log err "[UPD] Install path not set or invalid: ${install_path:-<unset>}"
        return 1
    fi
    if [ ! -d "$install_path" ]; then
        log err "[UPD] Current installation not found at $install_path"
        return 1
    fi

    local rollback_dir=""
    if [ "$target" = "last" ]; then
        rollback_dir="$(find "$install_parent" -maxdepth 1 -type d -name "${install_name}_rollback_*" 2>/dev/null | sort -r | head -n1)"
        if [ -z "$rollback_dir" ]; then
            log err "[UPD] No rollback directory found in $install_parent"
            return 1
        fi
    else
        if [ -d "$target" ]; then
            rollback_dir="$target"
        elif [ -d "${install_parent%/}/$target" ]; then
            rollback_dir="${install_parent%/}/$target"
        else
            log err "[UPD] Rollback directory not found: $target"
            return 1
        fi
    fi

    local rollback_name
    rollback_name="$(basename "$rollback_dir")"

    if [ "${args[force]:-${NAMED_ARGS[force]:-false}}" != true ]; then
        if ! prompt_confirm "UPD_ROLLBACK" "no" "Rollback to ${rollback_name}? (yes/no):" false 60; then
            log info "[UPD] Rollback cancelled."
            return 0
        fi
    else
        log info "[UPD] Force flag set. Proceeding with rollback."
    fi

    local timestamp
    timestamp="$(date +'%Y%m%d_%H%M%S')"
    local new_rollback="${install_parent}/${install_name}_rollback_${timestamp}"

    log info "[UPD] Moving current install to rollback: $(basename "$new_rollback")"
    safe_move_or_copy_and_clean "$install_path" "$new_rollback" move || {
        log err "[UPD] Failed to move current installation to rollback."
        return 1
    }

    log info "[UPD] Restoring rollback: ${rollback_name}"
    safe_move_or_copy_and_clean "$rollback_dir" "$install_path" move || {
        log err "[UPD] Failed to restore rollback directory."
        return 1
    }
    enforce_ownership "$install_path"
    log ok "[UPD] Rollback activated: ${rollback_name}"
    return 0
}
