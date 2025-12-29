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
    elif [[ -z "$mode" ]]; then
        if [[ -t 0 ]]; then
            local choice
            choice=$(prompt_var "INSTALL_MODE" "provisioned" \
                "Install type? (provisioned/wizard) [recommended: provisioned]:" false 60) || return 1
            choice="${choice,,}"
            case "$choice" in
                provisioned|provision|prov|p)
                    mode="Provisioned"
                    NAMED_ARGS[provision]=true
                    log info "[TAR] Provisioned install selected (recommended)."
                    ;;
                wizard|guided|gui|clean|g)
                    mode="Wizard"
                    log info "[TAR] Wizard install selected."
                    ;;
                *)
                    mode="Provisioned"
                    NAMED_ARGS[provision]=true
                    log warn "[TAR] Unknown choice; defaulting to provisioned install."
                    ;;
            esac
        else
            log info "[TAR] Non-interactive install; use --provision for recommended provisioned install."
        fi
    fi
    local env_file timestamp latest_version response source_dir
    timestamp="$(date +'%Y%m%d_%H%M%S')"
    latest_version="$(get_latest_version)"
    local install_path="${INM_INSTALLATION_PATH%/}"
    local install_parent
    install_parent="$(dirname "$install_path")"
    local install_name
    install_name="$(basename "$install_path")"
    local force="${NAMED_ARGS[force]:-${force_update:-false}}"

    if [ "$mode" = "Provisioned" ] && [[ "$force" != true ]]; then
        if [[ -n "$install_path" && -d "$install_path" ]] && find "$install_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            if [[ -t 0 ]]; then
                log warn "[TAR] Provisioned install is destructive."
                log info "[TAR] Continue? Type 'yes' to proceed:"
                if ! read -r -t 60 response; then
                    log warn "[TAR] No response within 60 seconds. Installation aborted."
                    return 1
                fi
                if [[ ! "$response" =~ ^([Yy]([Ee][Ss])?)$ ]]; then
                    log info "[TAR] Installation aborted by user."
                    return 1
                fi
            else
                log err "[TAR] Provisioned install is destructive. Re-run with --force."
                return 1
            fi
        fi
    fi

    if [ "$mode" = "Provisioned" ]; then
        local provision_rel="${INM_PROVISION_ENV_FILE:-.inmanage/.env.provision}"
        if [ -n "${INM_BASE_DIRECTORY:-}" ]; then
            env_file="${INM_BASE_DIRECTORY%/}/${provision_rel#/}"
        else
            env_file="$provision_rel"
            if [[ "$env_file" != /* ]]; then
                env_file="$(pwd)/${env_file}"
            fi
        fi
        # If migration backup hint present, stash for restore phase
        if [ -z "${INM_MIGRATION_BACKUP:-}" ] && [ -f "$env_file" ]; then
            INM_MIGRATION_BACKUP=$(grep -E '^INM_MIGRATION_BACKUP=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2-)
        fi
    else
        env_file="${install_parent}/${install_name}_temp/.env.example"
    fi

    if declare -F assert_file_path >/dev/null 2>&1; then
        assert_file_path "$env_file" "Provision file path" || return 1
    elif [ -d "$env_file" ]; then
        log err "[TAR] Provision file path resolves to a directory: $env_file"
        return 1
    fi

    if [ "$mode" = "Provisioned" ]; then
        if [[ -t 0 ]]; then
            local must_create=false
            local use_existing=false
            if [ ! -f "$env_file" ]; then
                if prompt_confirm "CREATE_PROVISION" "yes" "No provision file found. Create one now? [Y/n]" false 60; then
                    must_create=true
                else
                    log info "[PROV] Provision file not created."
                fi
            else
                if [[ "${NAMED_ARGS[provision]:-false}" == "true" ]]; then
                    use_existing=true
                    log info "[PROV] Using provision file: $env_file"
                elif ! prompt_confirm "USE_EXISTING_PROVISION" "yes" "Provision file exists. Use it? (no = create a new one) [Y/n]" false 60; then
                    must_create=true
                else
                    use_existing=true
                fi
            fi

            if [ "$must_create" = true ]; then
                local saved_provision_file="${NAMED_ARGS[provision_file]:-}"
                NAMED_ARGS[provision_file]="$env_file"
                spawn_provision_file || return 1
                if [ -n "$saved_provision_file" ]; then
                    NAMED_ARGS[provision_file]="$saved_provision_file"
                else
                    unset 'NAMED_ARGS[provision_file]'
                fi
                use_existing=true
            fi

            if [ "$use_existing" = true ] && [ -f "$env_file" ]; then
                local editor=""
                if command -v nano >/dev/null 2>&1; then
                    editor="nano"
                elif command -v vi >/dev/null 2>&1; then
                    editor="vi"
                fi

                if [ -n "$editor" ] && { [ "$must_create" = true ] || [[ "${NAMED_ARGS[provision]:-false}" != "true" ]]; }; then
                    log info "[PROV] Opening provision file in ${editor}."
                    log info "[PROV] If you're not familiar with ${editor}, please review its basics first."
                    log info "[PROV] For .env values, see Invoice Ninja docs. DB_ELEVATED_* is only for creating DB/user."
                    "$editor" "$env_file"
                elif [ -z "$editor" ] && { [ "$must_create" = true ] || [[ "${NAMED_ARGS[provision]:-false}" != "true" ]]; }; then
                    log warn "[PROV] No editor found (nano/vi). Edit manually: $env_file"
                fi
            elif [ -f "$env_file" ]; then
                log info "[PROV] Using provision file: $env_file"
            else
                log warn "[PROV] Provision file not found at: $env_file"
            fi
        else
            log warn "[PROV] Provision file missing: $env_file"
            log info "[PROV] Run 'inmanage core provision spawn' or 'inmanage core install --help'."
        fi
    fi

    if declare -F run_hook >/dev/null 2>&1; then
        run_hook "pre-install" || return 1
    fi

    if [ -d "$install_path" ]; then
        local src_path="$install_path"
        local rollback_dir="${install_parent}/${install_name}_rollback_${timestamp}"
        if ! find "$install_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            log warn "[TAR] App directory exists but appears empty; archiving anyway."
        fi

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

        safe_move_or_copy_and_clean "$src_path" "$rollback_dir" new || {
            log err "[TAR] Failed to archive old installation"
            return 1
        }
    fi

    log info "[TAR] Installation begins"

    source_dir="$(download_ninja "$latest_version")" || {
        log err "[TAR] Download failed"
        return 1
    }

    local extracted
    extracted="$(mktemp -d)"
    if ! spinner_run "Extracting Invoice Ninja..." tar -xzf "$source_dir/invoiceninja_v$latest_version.tar.gz" -C "$extracted"; then
        log err "[TAR] Failed to extract Invoice Ninja archive."
        rm -rf "$extracted"
        return 1
    fi

    local source_root="$extracted"
    mapfile -t top_entries < <(find "$extracted" -mindepth 1 -maxdepth 1 -print)
    if [[ ${#top_entries[@]} -eq 1 && -d "${top_entries[0]}" ]]; then
        source_root="${top_entries[0]}"
    fi

    local temp_dir="${install_parent}/${install_name}_temp"
    mkdir -p "$install_parent" || {
        log err "[TAR] Failed to create install parent: $install_parent"
        rm -rf "$extracted"
        return 1
    }
    rm -rf "$temp_dir"
    log info "[TAR] Preparing clean installation from archive: $source_dir/invoiceninja_v$latest_version.tar.gz"
    safe_move_or_copy_and_clean "$source_root" "$temp_dir" move || {
        log err "[TAR] Failed to move/copy extracted files"
        rm -rf "$extracted"
        return 1
    }
    rm -rf "$extracted"

    local archived_dir="${install_parent}/${install_name}_rollback_${timestamp}"
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
        if [ "$mode" = "Provisioned" ]; then
            sed -i '/^# INMANAGE_PROVISION_BEGIN$/,/^# INMANAGE_PROVISION_END$/d' \
                "${install_parent}/${install_name}_temp/.env" 2>/dev/null || true
        fi
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
    if declare -F enforce_ownership >/dev/null 2>&1; then
        enforce_ownership "$install_path"
    fi

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
        export INM_PROVISION_FILE_USED="$env_file"
        provision_post_install || return 1
    else
        local cron_jobs="${NAMED_ARGS[cron_jobs]:-${NAMED_ARGS[cron-jobs]:-scheduler}}"
        local cron_user="${INM_ENFORCED_USER:-$(whoami)}"
        local cron_ok=true
        local cron_skipped=false
        local cron_mode="${NAMED_ARGS[cron_mode]:-${NAMED_ARGS[cron-mode]:-auto}}"
        local no_cron="${NAMED_ARGS[no_cron_install]:-${NAMED_ARGS[no-cron-install]:-false}}"
        local no_backup_cron="${NAMED_ARGS[no_backup_cron]:-${NAMED_ARGS[no-backup-cron]:-false}}"
        local backup_time="${NAMED_ARGS[backup_time]:-${NAMED_ARGS[backup-time]:-03:24}}"
        if [[ "$no_backup_cron" == true ]]; then
            cron_jobs="scheduler"
        fi
        if [[ "$no_cron" == true ]]; then
            log info "[TAR] Cron install skipped by flag (--no-cron-install)."
            cron_ok=false
            cron_skipped=true
        else
            if ! install_cronjob "user=$cron_user" "jobs=$cron_jobs" "mode=$cron_mode" "backup_time=$backup_time"; then
                cron_ok=false
            fi
        fi
        print_wizard_summary "$cron_ok" "$cron_jobs" "$cron_skipped"
    fi

    if declare -F run_hook >/dev/null 2>&1; then
        run_hook "post-install" || return 1
    fi

    run_artisan config:clear || log warn "[TAR] artisan config:clear failed"
    run_artisan cache:clear || log warn "[TAR] artisan cache:clear failed"

    cd "$INM_BASE_DIRECTORY" || return 1
    return 0
}
