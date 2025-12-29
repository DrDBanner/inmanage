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
    local rollback_dirs
    local install_parent
    local install_name
    local keep="${INM_KEEP_BACKUPS:-2}"
    install_parent="$(dirname "${INM_INSTALLATION_PATH%/}")"
    install_name="$(basename "${INM_INSTALLATION_PATH%/}")"
    if [ -z "$install_name" ] || [ "$install_name" = "." ]; then
        install_name="$(basename "${INM_INSTALLATION_DIRECTORY}")"
    fi

    update_dirs=$(find "$install_parent" -maxdepth 1 -type d -name "${install_name}_*" ! -name "${install_name}_rollback_*" 2>/dev/null | sort -r | tail -n +$((keep + 1)))
    rollback_dirs=$(find "$install_parent" -maxdepth 1 -type d -name "${install_name}_rollback_*" 2>/dev/null | sort -r | tail -n +$((keep + 1)))

    if [ -n "$update_dirs" ]; then
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            safe_rm_rf "$dir" "$install_parent" || {
                log err "[COV] Failed to clean up old versions."
                exit 1
            }
        done <<< "$update_dirs"
    fi
    if [ -n "$rollback_dirs" ]; then
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            safe_rm_rf "$dir" "$install_parent" || {
                log err "[COV] Failed to clean up old rollbacks."
                exit 1
            }
        done <<< "$rollback_dirs"
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
    local keep="${INM_KEEP_BACKUPS:-2}"

    backup_items=$(find "$backup_path" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) | sort -r | tail -n +$((keep + 1)))

    if [ -n "$backup_items" ]; then
        while IFS= read -r item; do
            [[ -z "$item" ]] && continue
            safe_rm_rf "$item" "$backup_path" || {
                log err "[COB] Failed to clean up old backup items."
                exit 1
            }
        done <<< "$backup_items"
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
    local keep="${INM_KEEP_BACKUPS:-2}"
    local cache_keep="${INM_CACHE_GLOBAL_RETENTION:-3}"
    log info "[CLEAN] Removing old versions/backups/cache (keep backups/rollbacks: ${keep}, cache: ${cache_keep})"
    cleanup_old_versions
    cleanup_old_backups
    cleanup_cache
}
