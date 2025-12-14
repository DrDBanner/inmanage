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

    local installed_version latest_version timestamp response source_dir
    timestamp="$(date +'%Y%m%d_%H%M%S')"

    installed_version=$(get_installed_version)
    latest_version="${args[version]:-$(get_latest_version)}"

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

    source_dir="$(download_ninja "$latest_version")" || {
        log err "[UPD] Download failed."
        return 1
    }

    local install_path="${INM_INSTALLATION_PATH%/}"
    local install_parent
    install_parent="$(dirname "$install_path")"
    local install_name
    install_name="$(basename "$install_path")"
    local new_dir="${install_parent}/${install_name}_$latest_version"

    log info "[UPD] Preparing new version directory: $new_dir"

    rm -rf "$new_dir"
    mkdir -p "$new_dir"

    log info "[UPD] Copying from cache to $new_dir"
    cp -a "$source_dir/." "$new_dir/" || {
        log err "[UPD] Failed to copy files to new directory"
        return 1
    }

    log info "[UPD] Copying .env to $new_dir"
    cp "$INM_ENV_FILE" "$new_dir/.env" || {
        log err "[UPD] Failed to copy .env"
        return 1
    }

    log info "[UPD] Running artisan migrations and optimize tasks in new version"
    if ! run_artisan_in "$new_dir" migrate --force || ! run_artisan_in "$new_dir" optimize; then
        log err "[UPD] Artisan migrate/optimize failed in new version."
        return 1
    fi

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

    log info "[UPD] Running post-update artisan tasks"
    run_artisan optimize || log warn "[UPD] artisan optimize failed"
    run_artisan migrate --force || log warn "[UPD] artisan migrate failed"
    run_artisan ninja:post-update || log warn "[UPD] artisan post-update failed"
    run_artisan ninja:check-data || log warn "[UPD] artisan check-data failed"
    run_artisan ninja:translations || log warn "[UPD] artisan translations failed"
    run_artisan ninja:design-update || log warn "[UPD] artisan design-update failed"
    run_artisan up || log warn "[UPD] artisan up failed"

    do_snappdf || log warn "[UPD] Snappdf setup failed"
    cleanup || log warn "[UPD] Cache cleanup failed"
    log ok "[UPD] Update completed successfully!"
}
