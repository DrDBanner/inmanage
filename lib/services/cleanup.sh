#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_CLEANUP_LOADED:-} ]] && return
__SERVICE_CLEANUP_LOADED=1

# ---------------------------------------------------------------------
# cleanup_old_versions()
# ---------------------------------------------------------------------
cleanup_old_versions() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cleanup of old versions."
        return 0
    fi
    log info "[COV] Cleaning up old update directory versions."
    local update_dirs
    local install_parent
    install_parent="$(dirname "${INM_INSTALLATION_PATH%/}")"
    update_dirs=$(find "$install_parent" -maxdepth 1 -type d -name "$(basename "$INM_INSTALLATION_DIRECTORY")_*" | sort -r | tail -n +$((INM_KEEP_BACKUPS + 1)))

    if [ -n "$update_dirs" ]; then
        echo "$update_dirs" | xargs -r rm -rf || {
            log err "[COV] Failed to clean up old versions."
            exit 1
        }
    fi
}

# ---------------------------------------------------------------------
# cleanup_old_backups()
# ---------------------------------------------------------------------
cleanup_old_backups() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cleanup of old backups."
        return 0
    fi
    log info "[COB] Cleaning up old backups."
    local backup_path="$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY"
    local backup_items

    backup_items=$(find "$backup_path" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) | sort -r | tail -n +$((INM_KEEP_BACKUPS + 1)))

    if [ -n "$backup_items" ]; then
        echo "$backup_items" | xargs -r rm -rf || {
            log err "[COB] Failed to clean up old backup items."
            exit 1
        }
    fi
    log debug "[COB] Cleaning up done."
}

# ---------------------------------------------------------------------
# cleanup()
# ---------------------------------------------------------------------
cleanup() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cleanup."
        return 0
    fi
    log info "[CLEAN] Removing old versions/backups/cache"
    cleanup_old_versions
    cleanup_old_backups
    cleanup_cache
}
