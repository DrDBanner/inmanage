#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_INSTALL_LOADED:-} ]] && return
__SERVICE_INSTALL_LOADED=1

# ---------------------------------------------------------------------
# run_installation()
# Run the Invoice Ninja installation flow (provisioned or wizard).
# Consumes: args: mode; env: INM_*; globals: NAMED_ARGS; deps: prompt_var/prompt_confirm/get_latest_version/etc.
# Computes: install staging, provisioning, cron and post-install actions.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
run_installation() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping installation."
        return 0
    fi
    unset INM_INSTALL_ROLLBACK_DIR
    local mode="$1"
    if [[ -z "$mode" && "${NAMED_ARGS[provision]:-false}" == "true" ]]; then
        mode="Provisioned"
        log debug "[TAR] Provision mode enabled via --provision."
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
                    log debug "[TAR] Provisioned install selected (recommended)."
                    ;;
                wizard|guided|gui|clean|g)
                    mode="Wizard"
                    log debug "[TAR] Wizard install selected."
                    ;;
                *)
                    mode="Provisioned"
                    NAMED_ARGS[provision]=true
                    log warn "[TAR] Unknown choice; defaulting to provisioned install."
                    ;;
            esac
        else
            log debug "[TAR] Non-interactive install; use --provision for recommended provisioned install."
        fi
    fi
    local env_file timestamp latest_version source_dir
    timestamp="$(date +'%Y%m%d_%H%M%S')"
    export INM_INSTALL_TIMESTAMP="$timestamp"
    latest_version="$(get_latest_version)"
    local install_path="${INM_INSTALLATION_PATH%/}"
    local install_parent
    install_parent="$(dirname "$install_path")"
    local install_name
    install_name="$(basename "$install_path")"
    local force="${NAMED_ARGS[force]:-${force_update:-false}}"
    if [ "$mode" = "Provisioned" ] && [ ! -e "$install_path" ]; then
        # shellcheck disable=SC2034
        INM_PROVISION_FRESH_INSTALL=true
    fi

    if [ "$mode" = "Provisioned" ] && [[ "$force" != true ]] && [ -e "$install_path" ]; then
        if [[ -t 0 ]]; then
            log warn "[TAR] Provisioned install is destructive."
            if prompt_confirm "PROV_DESTRUCTIVE" "no" "[TAR] Continue? Type 'yes' to proceed:" false 60; then
                NAMED_ARGS[force]=true
                force=true
            else
                log info "[TAR] Installation aborted by user."
                return 1
            fi
        else
            log err "[TAR] Provisioned install is destructive. Re-run with --force."
            return 1
        fi
    fi

    if [ "$mode" = "Provisioned" ]; then
        local provision_rel="${INM_PROVISION_ENV_FILE:-.inmanage/.env.provision}"
        if [ -n "${INM_PATH_BASE_DIR:-}" ]; then
            env_file="${INM_PATH_BASE_DIR%/}/${provision_rel#/}"
        else
            env_file="$provision_rel"
            if [[ "$env_file" != /* ]]; then
                env_file="$(pwd)/${env_file}"
            fi
        fi
        # If migration backup hint present, stash for restore phase
        if [ -z "${INM_BACKUP_MIGRATION_SOURCE:-}" ] && [ -f "$env_file" ]; then
            INM_BACKUP_MIGRATION_SOURCE="$(read_env_value_safe "$env_file" "INM_BACKUP_MIGRATION_SOURCE" 2>/dev/null)"
        fi
    else
        env_file="${install_parent}/${install_name}_temp/.env.example"
    fi

    assert_file_path "$env_file" "Provision file path" || return 1

    if [ "$mode" = "Provisioned" ]; then
        if [[ -t 0 ]]; then
            local must_create=false
            local use_existing=false
            if [ ! -f "$env_file" ]; then
                if prompt_confirm "CREATE_PROVISION" "yes" "No provision file found. Create one now? [Y/n]" false 60; then
                    must_create=true
                else
                    log debug "[PROV] Provision file not created."
                fi
            else
                if [[ "${NAMED_ARGS[provision]:-false}" == "true" ]]; then
                    use_existing=true
                    log debug "[PROV] Using provision file: $env_file"
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
                    log debug "[PROV] If you're not familiar with ${editor}, please review its basics first."
                    log debug "[PROV] For .env values, see Invoice Ninja docs. DB_ELEVATED_* is only for creating DB/user."
                    "$editor" "$env_file"
                elif [ -z "$editor" ] && { [ "$must_create" = true ] || [[ "${NAMED_ARGS[provision]:-false}" != "true" ]]; }; then
                    log warn "[PROV] No editor found (nano/vi). Edit manually: $env_file"
                fi
            elif [ -f "$env_file" ]; then
                log debug "[PROV] Using provision file: $env_file"
            else
                log warn "[PROV] Provision file not found at: $env_file"
            fi
        else
            log warn "[PROV] Provision file missing: $env_file"
            log info "[PROV] Run 'inm spawn provision-file' or 'inm core install --help'."
        fi
    fi

    if [ "$mode" = "Provisioned" ] && [ -f "$env_file" ]; then
        apply_inm_keys_from_provision "$env_file"
        resolve_env_paths || true
        local new_env_file=""
        local provision_rel="${INM_PROVISION_ENV_FILE:-.inmanage/.env.provision}"
        if [ -n "${INM_PATH_BASE_DIR:-}" ]; then
            new_env_file="${INM_PATH_BASE_DIR%/}/${provision_rel#/}"
        else
            new_env_file="$provision_rel"
            if [[ "$new_env_file" != /* ]]; then
                new_env_file="$(pwd)/${new_env_file}"
            fi
        fi
        if [ -f "$new_env_file" ]; then
            env_file="$new_env_file"
            if [ -z "${INM_BACKUP_MIGRATION_SOURCE:-}" ]; then
                INM_BACKUP_MIGRATION_SOURCE="$(read_env_value_safe "$env_file" "INM_BACKUP_MIGRATION_SOURCE" 2>/dev/null)"
            fi
        elif [[ "$new_env_file" != "$env_file" ]]; then
            log warn "[PROV] Provision file path from INM_* not found; keeping $env_file"
        fi
    fi

    run_hook "pre-install" || return 1

    if [ -d "$install_path" ]; then
        local src_path="$install_path"
        local rollback_dir="${install_parent}/${install_name}_rollback_${timestamp}"
        if ! find "$install_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            log warn "[TAR] App directory exists but appears empty; archiving anyway."
        fi

        # shellcheck disable=SC2154
        if [ "$force_update" != true ]; then
            log warn "[TAR] App directory already exists – archive current version?"
            if ! prompt_confirm "INSTALL_ARCHIVE" "no" "[TAR] Proceed with installation and archive the current directory? (yes/no):" false 60; then
                log info "[TAR] Installation aborted by user."
                return 0
            fi
        else
            log debug "[TAR] Forced install – archiving current version"
        fi

        if ! fs_with_smo_log_level debug safe_move_or_copy_and_clean "$src_path" "$rollback_dir" new; then
            log err "[TAR] Failed to archive old installation"
            return 1
        fi
        # shellcheck disable=SC2034
        INM_INSTALL_ROLLBACK_DIR="$rollback_dir"
        log info "[TAR] Previous installation archived."
    fi

    log info "[TAR] Installation begins"
    log debug "[TAR] Preparing release archive (v${latest_version})"

    source_dir="$(download_ninja "$latest_version")" || {
        log err "[TAR] Download failed"
        return 1
    }

    local extracted
    extracted="$(mktemp -d)"
    if ! INM_SPINNER_HEARTBEAT=0 spinner_run_mode normal "Extracting Invoice Ninja..." tar_extract_fallback "$source_dir/invoiceninja_v$latest_version.tar.gz" "$extracted"; then
        log err "[TAR] Failed to extract Invoice Ninja archive."
        safe_rm_rf "$extracted" "$(dirname "$extracted")" || true
        return 1
    fi

    local source_root
    source_root="$(fs_resolve_single_root_dir "$extracted")"

    local temp_dir="${install_parent}/${install_name}_temp"
    log debug "[TAR] Staging files for deployment"
    log debug "[TAR] Staging extracted files for atomic switch: $temp_dir (source: $source_dir/invoiceninja_v$latest_version.tar.gz)"
    if ! fs_stage_dir "$source_root" "$temp_dir" "$install_parent" move "debug"; then
        log err "[TAR] Failed to move/copy extracted files"
        safe_rm_rf "$extracted" "$(dirname "$extracted")" || true
        return 1
    fi
    safe_rm_rf "$extracted" "$(dirname "$extracted")" || true

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
            local env_target="${install_parent}/${install_name}_temp/.env"
            local sed_script='/^# INMANAGE_PROVISION_BEGIN$/,/^# INMANAGE_PROVISION_END$/d;/^[[:space:]]*(export[[:space:]]+)?INM_[A-Za-z0-9_]*[[:space:]]*=/d'
            if ! sed -i '' -e "$sed_script" "$env_target" 2>/dev/null; then
                sed -i -e "$sed_script" "$env_target" 2>/dev/null || true
            fi
        fi
        chmod 600 "${install_parent}/${install_name}_temp/.env" || \
            log warn "[TAR] chmod 600 failed on .env"
    else
        log warn "[TAR] No .env found – installation will not be functional without manual setup"
        # shellcheck disable=SC2154
        if [ "$force_update" = true ]; then
            log debug "[TAR] Force mode enabled – proceeding anyway"
        else
            log warn "[TAR] Abort or continue? Type 'yes' to proceed:"
            read -r confirm
            [[ "$confirm" != "yes" ]] && {
                log info "[TAR] Installation cancelled by user"
                return 1
            }
        fi
    fi

    log debug "[TAR] Deploying new installation"
    if ! fs_with_smo_log_level debug safe_move_or_copy_and_clean "${install_parent}/${install_name}_temp" "$install_path"; then
        log err "[TAR] Failed to deploy new installation"
        return 1
    fi
    log info "[TAR] Installation files deployed successfully."
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

    if [ ! -x "$install_path/artisan" ]; then
        chmod +x "$install_path/artisan" || {
            log err "[TAR] Cannot fix artisan permissions"
            return 1
        }
    fi

    log info "[TAR] Running post-installation artisan tasks"

    if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
        run_artisan key:generate --force || log warn "[TAR] artisan key:generate failed"
        run_artisan optimize || log warn "[TAR] artisan optimize failed"
        run_artisan up || log warn "[TAR] artisan up failed"
        run_artisan ninja:translations || log warn "[TAR] artisan translations failed"
    else
        run_artisan key:generate --force >/dev/null 2>&1 || log warn "[TAR] artisan key:generate failed"
        run_artisan optimize >/dev/null 2>&1 || log warn "[TAR] artisan optimize failed"
        run_artisan up >/dev/null 2>&1 || log warn "[TAR] artisan up failed"
        run_artisan ninja:translations >/dev/null 2>&1 || log warn "[TAR] artisan translations failed"
    fi
    do_snappdf || log warn "[TAR] Snappdf setup failed"

    # shellcheck disable=SC2059
    if [ "$mode" = "Provisioned" ]; then
        provision_prepare_database || return 1
        # Migration-aware: if INM_BACKUP_MIGRATION_SOURCE is set, attempt restore after deploy
        if [ -n "${INM_BACKUP_MIGRATION_SOURCE:-}" ]; then
            log debug "[PROV] Migration backup detected: ${INM_BACKUP_MIGRATION_SOURCE}"
            local backup_path=""
            if [ "${INM_BACKUP_MIGRATION_SOURCE}" = "LATEST" ]; then
                if [ -d "${INM_BACKUP_DIR:-./.backups}" ]; then
                    # shellcheck disable=SC2012
                    backup_path=$(ls -1t "${INM_BACKUP_DIR:-./.backups}"/InvoiceNinja_* 2>/dev/null | head -n1)
                fi
            else
                backup_path="$INM_BACKUP_MIGRATION_SOURCE"
            fi
            if [ -n "$backup_path" ]; then
                log debug "[PROV] Restoring migration backup: $backup_path"
                local saved_named=("${NAMED_ARGS[@]}")
                NAMED_ARGS[file]="$backup_path"
                # shellcheck disable=SC2154
                NAMED_ARGS[include_app]=true
                NAMED_ARGS[force]=true
                # shellcheck disable=SC2154
                NAMED_ARGS[purge]=true
                call_with_named_args run_restore || log warn "[PROV] Migration restore failed; continuing with fresh setup."
                NAMED_ARGS=("${saved_named[@]}")
            else
                log warn "[PROV] No backup found for migration hint (${INM_BACKUP_MIGRATION_SOURCE}); continuing with fresh setup."
            fi
        fi
        export INM_PROVISION_FILE_USED="$env_file"
        provision_post_install || return 1
    else
        local cron_jobs
        cron_jobs="$(args_get - "artisan" cron_jobs jobs)"
        local cron_jobs_set=false
        if [[ -n "${NAMED_ARGS[cron_jobs]:-}" || -n "${NAMED_ARGS[jobs]:-}" ]]; then
            cron_jobs_set=true
        fi
        local cron_user="${INM_EXEC_USER:-$(whoami)}"
        local cron_ok=true
        local cron_skipped=false
        local cron_mode
        cron_mode="$(args_get - "auto" cron_mode mode)"
        local no_cron
        no_cron="$(args_get - "false" no_cron_install no_cron)"
        local no_backup_cron
        no_backup_cron="$(args_get - "false" no_backup_cron)"
        local backup_time
        backup_time="$(args_get - "03:24" backup_time)"
        if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "${INM_SELF_ENV_FILE:-}" ]; then
            load_env_file_raw "$INM_SELF_ENV_FILE" || true
        fi
        local hb_enabled="${INM_NOTIFY_HEARTBEAT_ENABLE:-}"
        local hb_time="${INM_NOTIFY_HEARTBEAT_TIME:-}"
        if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "${INM_SELF_ENV_FILE:-}" ]; then
            local cfg_file="$INM_SELF_ENV_FILE"
            if [[ "$cfg_file" != /* ]] && [ -n "${INM_PATH_BASE_DIR:-}" ]; then
                cfg_file="${INM_PATH_BASE_DIR%/}/${cfg_file#/}"
            fi
            local hb_from_file
            local hb_time_from_file
            hb_from_file="$(read_env_value_safe "$cfg_file" "INM_NOTIFY_HEARTBEAT_ENABLE" 2>/dev/null)"
            hb_time_from_file="$(read_env_value_safe "$cfg_file" "INM_NOTIFY_HEARTBEAT_TIME" 2>/dev/null)"
            if [ -n "$hb_from_file" ]; then
                hb_enabled="$hb_from_file"
            fi
            if [ -n "$hb_time_from_file" ]; then
                hb_time="$hb_time_from_file"
            fi
        fi
        hb_enabled="${hb_enabled,,}"
        hb_enabled="${hb_enabled//[[:space:]]/}"
        local heartbeat_time
        heartbeat_time="$(args_get - "${hb_time:-${INM_NOTIFY_HEARTBEAT_TIME:-06:00}}" heartbeat_time)"
        local cron_jobs_lc="${cron_jobs,,}"
        if args_is_true "$hb_enabled"; then
            if [[ ",${cron_jobs_lc}," != *",heartbeat,"* && ",${cron_jobs_lc}," != *",all,"* ]]; then
                if [[ "$cron_jobs_set" == true ]]; then
                    log debug "[TAR] Heartbeat enabled but cron jobs set explicitly; leaving jobs as '${cron_jobs}'."
                else
                    cron_jobs="${cron_jobs},heartbeat"
                fi
            fi
        fi
        if args_is_true "$no_backup_cron"; then
            cron_jobs="artisan"
        fi
        if args_is_true "$no_cron"; then
            log debug "[TAR] Cron install skipped by flag (--no-cron-install)."
            cron_ok=false
            cron_skipped=true
        else
            if ! install_cronjob "user=$cron_user" "jobs=$cron_jobs" "mode=$cron_mode" "backup_time=$backup_time" "heartbeat_time=$heartbeat_time"; then
                cron_ok=false
            fi
        fi
        if [[ "$cron_ok" == true ]]; then
            maybe_setup_heartbeat_notifications "TAR"
        fi
        print_wizard_summary "$cron_ok" "$cron_jobs" "$cron_skipped"
    fi

    run_hook "post-install" || return 1

    if [[ "${NAMED_ARGS[override_enforced_user]:-}" == "true" || "${INM_OVERRIDE_ENFORCED_USER:-}" == "true" ]]; then
        if [[ "$EUID" -eq 0 && -n "${INM_EXEC_USER:-}" ]]; then
            local cfg_dir=""
            if [[ -n "${INM_SELF_ENV_FILE:-}" ]]; then
                cfg_dir="$(dirname "$INM_SELF_ENV_FILE")"
            fi
            if [[ -n "$cfg_dir" && -d "$cfg_dir" ]]; then
                log debug "[INSTALL] Fixing ownership for CLI config: $cfg_dir"
                enforce_ownership "$cfg_dir" "$INM_SELF_ENV_FILE"
            fi
        fi
    fi

    if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
        run_artisan config:clear || log warn "[TAR] artisan config:clear failed"
        run_artisan cache:clear || log warn "[TAR] artisan cache:clear failed"
    else
        run_artisan config:clear >/dev/null 2>&1 || log warn "[TAR] artisan config:clear failed"
        run_artisan cache:clear >/dev/null 2>&1 || log warn "[TAR] artisan cache:clear failed"
    fi

    cd "$INM_PATH_BASE_DIR" || return 1
    return 0
}

# ---------------------------------------------------------------------
# run_install_rollback()
# Rolls back to an archived installation directory (install_name_rollback_*).
# Usage: inm core install rollback --latest|--name=DIR
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# run_install_rollback()
# Roll back to a previous install snapshot.
# Consumes: args: selection; env: INM_INSTALLATION_PATH; deps: safe_move.
# Computes: app directory swap to rollback version.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
run_install_rollback() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping install rollback."
        return 0
    fi

    # shellcheck disable=SC2034
    local -A args=()
    parse_named_args args "$@"
    local target
    target="$(app_parse_rollback_target args "latest" "$@")"

    local install_path="${INM_INSTALLATION_PATH%/}"
    local force
    force="$(args_get args "false" force)"
    app_run_rollback "INSTALL" "INSTALL_ROLLBACK" "$install_path" "$target" "$force"
}
