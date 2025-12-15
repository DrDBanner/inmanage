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

    log info "[UPD] Fetching Invoice Ninja $latest_version"

    local cache_dir
    cache_dir="$(download_ninja "$latest_version")" || {
        log err "[UPD] Download failed."
        return 1
    }
    # Extract from cache tarball
    local extracted
    extracted="$(mktemp -d)"
    if ! tar -xzf "$cache_dir/invoiceninja_v$latest_version.tar.gz" -C "$extracted"; then
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

    rm -rf "$new_dir"
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

    log info "[UPD] Moving previous installation to backup directory"
    local backup_dir="${install_parent}/${install_name}_backup_${timestamp}"
    if [ -d "$install_path" ]; then
        safe_move_or_copy_and_clean "$install_path" "$backup_dir" move || {
            log err "[UPD] Could not move current installation to backup."
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
}
