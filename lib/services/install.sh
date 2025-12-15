#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_INSTALL_LOADED:-} ]] && return
__SERVICE_INSTALL_LOADED=1

# ---------------------------------------------------------------------
# run_installation()
# ---------------------------------------------------------------------
run_installation() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping installation."
        return 0
    fi
    local mode="$1"
    if [[ -z "$mode" && "${NAMED_ARGS[provision]:-false}" == "true" ]]; then
        mode="Provisioned"
        log info "[TAR] Provision mode enabled via --provision."
    fi
    local env_file timestamp latest_version response source_dir
    timestamp="$(date +'%Y%m%d_%H%M%S')"
    latest_version="$(get_latest_version)"
    local install_path="${INM_INSTALLATION_PATH%/}"
    local install_parent
    install_parent="$(dirname "$install_path")"
    local install_name
    install_name="$(basename "$install_path")"

    if [ "$mode" = "Provisioned" ]; then
        env_file="${INM_BASE_DIRECTORY%/}/${INM_PROVISION_ENV_FILE#/}"
        # If migration backup hint present, stash for restore phase
        if [ -z "${INM_MIGRATION_BACKUP:-}" ] && [ -f "$env_file" ]; then
            INM_MIGRATION_BACKUP=$(grep -E '^INM_MIGRATION_BACKUP=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2-)
        fi
    else
        env_file="${install_parent}/${install_name}_temp/.env.example"
    fi

    if [ -d "$install_path" ]; then
        local src_path="$install_path"
        local dst_path="${install_parent}/_last_IN_${timestamp}"

        # shellcheck disable=SC2154
        if [ "$force_update" != true ]; then
            log warn "[TAR] App directory already exists – archive current version?"
            log info "[TAR] Proceed with installation and archive the current directory? (yes/no):"
            if ! read -r -t 60 response; then
                log warn "[TAR] No response within 60 seconds. Installation aborted."
                return 0
            fi
            if [[ ! "$response" =~ ^([Yy]([Ee][Ss])?)$ ]]; then
                log info "[TAR] Installation aborted by user."
                return 0
            fi
        else
            log info "[TAR] Forced install – archiving current version"
        fi

        safe_move_or_copy_and_clean "$src_path" "$dst_path" new || {
            log err "[TAR] Failed to archive old installation"
            return 1
        }
    fi

    log info "[TAR] Installation begins"

    source_dir="$(download_ninja "$latest_version")" || {
        log err "[TAR] Download failed"
        return 1
    }

    mkdir -p "${install_parent}/${install_name}_temp" || {
        log err "[TAR] Failed to create temp directory"
        return 1
    }
    log info "[TAR] Copying clean installation from cache: $source_dir"
    cp -a "$source_dir/." "${install_parent}/${install_name}_temp/" || {
        log err "[TAR] Failed to copy files from cache"
        return 1
    }

    local archived_dir="${install_parent}/_last_IN_${timestamp}"
    local target_dir="${install_parent}/${install_name}_temp"

    log debug "[TAR] Checking for .env*.inmanage files in: $archived_dir"

    shopt -s nullglob
    local restore_candidates=("$archived_dir"/.env*.inmanage)
    if [ ${#restore_candidates[@]} -gt 0 ]; then
        for file in "${restore_candidates[@]}"; do
            cp -f "$file" "$target_dir/" 2>/dev/null && \
                log debug "[TAR] Restored $(basename "$file") to $target_dir"
        done
    else
        log debug "[TAR] No .env*.inmanage files found for restore"
    fi
    shopt -u nullglob

    if [ -f "$env_file" ]; then
        cp "$env_file" "${install_parent}/${install_name}_temp/.env" || {
            log err "[TAR] Failed to place .env"
            return 1
        }
        chmod 600 "${install_parent}/${install_name}_temp/.env" || \
            log warn "[TAR] chmod 600 failed on .env"
    else
        log warn "[TAR] No .env found – installation will not be functional without manual setup"
        # shellcheck disable=SC2154
        if [ "$force_update" = true ]; then
            log info "[TAR] Force mode enabled – proceeding anyway"
        else
            log warn "[TAR] Abort or continue? Type 'yes' to proceed:"
            read -r confirm
            [[ "$confirm" != "yes" ]] && {
                log info "[TAR] Installation cancelled by user"
                return 1
            }
        fi
    fi

    safe_move_or_copy_and_clean "${install_parent}/${install_name}_temp" "$install_path" || {
        log err "[TAR] Failed to deploy new installation"
        return 1
    }

    if [ ! -x "$install_path/artisan" ]; then
        chmod +x "$install_path/artisan" || {
            log err "[TAR] Cannot fix artisan permissions"
            return 1
        }
    fi

    log info "[TAR] Running post-installation artisan tasks"

    run_artisan key:generate --force || log warn "[TAR] artisan key:generate failed"
    run_artisan optimize || log warn "[TAR] artisan optimize failed"
    run_artisan up || log warn "[TAR] artisan up failed"
    run_artisan ninja:translations || log warn "[TAR] artisan translations failed"
    do_snappdf || log warn "[TAR] Snappdf setup failed"

    # shellcheck disable=SC2059
    if [ "$mode" = "Provisioned" ]; then
        provision_prepare_database || return 1
        # Migration-aware: if INM_MIGRATION_BACKUP is set, attempt restore after deploy
        if [ -n "${INM_MIGRATION_BACKUP:-}" ]; then
            log info "[PROV] Migration backup detected: ${INM_MIGRATION_BACKUP}"
            local backup_path=""
            if [ "${INM_MIGRATION_BACKUP}" = "LATEST" ]; then
                if [ -d "${INM_BACKUP_DIRECTORY:-./.backups}" ]; then
                    backup_path=$(ls -1t "${INM_BACKUP_DIRECTORY:-./.backups}"/InvoiceNinja_* 2>/dev/null | head -n1)
                fi
            else
                backup_path="$INM_MIGRATION_BACKUP"
            fi
            if [ -n "$backup_path" ]; then
                log info "[PROV] Restoring migration backup: $backup_path"
                local saved_named=("${NAMED_ARGS[@]}")
                NAMED_ARGS[file]="$backup_path"
                NAMED_ARGS[include_app]=true
                NAMED_ARGS[force]=true
                NAMED_ARGS[purge]=true
                call_with_named_args run_restore || log warn "[PROV] Migration restore failed; continuing with fresh setup."
                NAMED_ARGS=("${saved_named[@]}")
            else
                log warn "[PROV] No backup found for migration hint (${INM_MIGRATION_BACKUP}); continuing with fresh setup."
            fi
        fi
        provision_post_install || return 1
    else
        printf "\n${BLUE}%s${RESET}\n" "========================================"
        printf "${GREEN}${BOLD}Setup Complete!${RESET}\n\n"
        printf "${WHITE}Open your browser at your configured address ${CYAN}https://your.url/setup${RESET} to complete database setup.${RESET}\n\n"
        printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
        printf "${BOLD}To install cronjobs automatically, use:${RESET}\n"
        printf "  ${CYAN}./inmanage.sh install_cronjob user=%s${RESET}\n" "$INM_ENFORCED_USER"
        printf "  Full explanation available via ${CYAN}./inmanage.sh -h${RESET}\n\n"
    fi

    cd "$INM_BASE_DIRECTORY" || return 1
    return 0
}
