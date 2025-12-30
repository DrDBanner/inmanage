#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_PROVISION_LOADED:-} ]] && return
__SERVICE_PROVISION_LOADED=1

# ---------------------------------------------------------------------
# Provision Service – Plan / TODO
# ---------------------------------------------------------------------
# Historical: users filled .env.example -> .env.provision; install --provision would
# create DB/user (with elevated creds), install app, move .env.provision -> .env,
# key:generate, migrate/seed, cache warm, create admin, cron/backup hints.
# Goal: centralize provision helpers, support migration backup hints, avoid duplication.
# Current helpers: spawn_provision_file, provision_post_install (migration restore happens in install flow).
# Pending: ensure DB creation via elevated creds when DB is absent, tighten dry-run hooks.

# ---------------------------------------------------------------------
# spawn_provision_file()
# Creates/updates .env.provision based on .env.example (preferred) or app env.
# Supports: --provision-file, --backup-file, --latest-backup, --force.
# ---------------------------------------------------------------------
spawn_provision_file() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would write provision file; skipping."
        return 0
    fi
    local target="${NAMED_ARGS[provision_file]:-${INM_PROVISION_ENV_FILE:-.inmanage/.env.provision}}"
    local force="${NAMED_ARGS[force]:-${force_update:-false}}"
    local migration_backup="${NAMED_ARGS[backup_file]:-${NAMED_ARGS[backup-file]:-${INM_MIGRATION_BACKUP:-}}}"
    local latest_backup="${NAMED_ARGS[latest_backup]:-${NAMED_ARGS[latest-backup]:-false}}"

    if [[ "$target" != /* ]]; then
        target="$(pwd)/${target}"
    fi
    if declare -F assert_file_path >/dev/null 2>&1; then
        assert_file_path "$target" "Provision file path" || return 1
    elif [[ -d "$target" || "$target" == */ ]]; then
        log err "[PROV] Provision file path resolves to a directory: $target"
        return 1
    fi

    mkdir -p "$(dirname "$target")" 2>/dev/null || {
        log err "[PROV] Cannot create directory for provision file: $(dirname "$target")"
        return 1
    }

    if [ -f "$target" ] && [ "$force" != true ]; then
        log warn "[PROV] Provision file exists: $target (use --force to overwrite)."
        return 0
    fi

    local env_example="${INM_ENV_EXAMPLE_FILE:-${INM_BASE_DIRECTORY%/}/.inmanage/.env.example}"
    if [[ "$env_example" != /* ]]; then
        env_example="$(pwd)/${env_example}"
    fi
    local src_env=""

    if [ -f "$env_example" ]; then
        src_env="$env_example"
    else
        log debug "[PROV] Downloading .env.example for provisioning"
        mkdir -p "$(dirname "$env_example")" 2>/dev/null || true
        curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} \
            "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" \
            -o "$env_example" || {
                log warn "[PROV] Failed to download .env.example; will try app env instead."
                env_example=""
            }
        if [ -f "$env_example" ]; then
            src_env="$env_example"
        fi
    fi

    if [ -z "$src_env" ] && [ -f "${INM_ENV_FILE:-}" ]; then
        src_env="$INM_ENV_FILE"
        log debug "[PROV] Seeding from app env: $src_env"
    elif [ -z "$src_env" ] && [ -f "${SCRIPT_DIR:-.}/.env.example" ]; then
        src_env="${SCRIPT_DIR:-.}/.env.example"
        log debug "[PROV] Seeding from bundled .env.example: $src_env"
    fi

    if [ -z "$src_env" ]; then
        log err "[PROV] No source env found (.env.example or app env)."
        return 1
    fi

    cp -f "$src_env" "$target" || {
        log err "[PROV] Failed to seed provision file from $src_env"
        return 1
    }

    if ! grep -q '^# INMANAGE_PROVISION_BEGIN$' "$target" 2>/dev/null; then
        local tmp="${target}.tmp.$$"
        {
            echo "# INMANAGE_PROVISION_BEGIN"
            echo "# This file is your unattended install plan for Invoice Ninja."
            echo "# Set any Invoice Ninja .env keys you need (APP_*, DB_*, MAIL_*, etc.)."
            echo "# Official env docs: https://invoiceninja.github.io/en/self-host-installation/#configure-environment"
            echo "# When you're done, run: inmanage core install --provision"
            echo "# Result: the app is installed and configured, you get a direct login,"
            echo "# and cron can be installed automatically if possible."
            echo "# INMANAGE_PROVISION_END"
            echo ""
            cat "$target"
        } > "$tmp" && mv "$tmp" "$target"
    fi

    if ! grep -q '^DB_ELEVATED_USERNAME=' "$target" 2>/dev/null; then
        sed -i '/^DB_PORT=/a DB_ELEVATED_USERNAME=\nDB_ELEVATED_PASSWORD=' "$target" 2>/dev/null || true
    fi
    if [ -n "$migration_backup" ]; then
        printf "\nINM_MIGRATION_BACKUP=%s\n" "$migration_backup" >> "$target"
        log debug "[PROV] Added migration backup reference: $migration_backup"
    elif [ "$latest_backup" = true ]; then
        printf "\nINM_MIGRATION_BACKUP=LATEST\n" >> "$target"
        log debug "[PROV] Will use latest backup during provisioned install."
    fi

    if [ -f "$target" ]; then
        chmod 600 "$target" 2>/dev/null || true
    else
        log warn "[PROV] Provision file not created at: $target"
        return 1
    fi
    log ok "[PROV] Provision file written: $target"
}

# ---------------------------------------------------------------------
# provision_post_install()
# Runs provision-specific post steps (migrate/seed, create admin, messages).
# ---------------------------------------------------------------------
provision_post_install() {
    log info "[PROV] Running provisioned post-install steps"

    local force="${NAMED_ARGS[force]:-${force_update:-false}}"
    local can_prompt=false
    [[ -t 0 && -t 1 ]] && declare -F prompt_confirm >/dev/null 2>&1 && can_prompt=true

    if [[ "$force" != true ]]; then
        local table_count=""
        local reason=""
        local prompt_msg=""

        if table_count=$(db_table_count 2>/dev/null); then
            if [[ "$table_count" -gt 0 ]]; then
                reason="existing tables: ${table_count}"
                prompt_msg="Database has ${table_count} existing tables. Backup and replace? (yes/no):"
            fi
        elif [[ "${INM_PROVISION_FRESH_INSTALL:-false}" != true ]]; then
            reason="table count unknown"
            prompt_msg="Database state is unknown (could not count tables). Backup and replace? (yes/no):"
        fi

        if [[ -n "$reason" ]]; then
            if [[ "$can_prompt" == true ]]; then
                if prompt_confirm "PROV_DESTRUCTIVE" "no" "$prompt_msg" false 120; then
                    force=true
                else
                    log err "[PROV] Provisioning aborted: ${reason}."
                    return 1
                fi
            else
                log err "[PROV] Provisioning is destructive (${reason}). Re-run with --force to proceed."
                return 1
            fi
        fi
    fi

    local no_backup="${NAMED_ARGS[no_backup]:-${NAMED_ARGS[no-backup]:-false}}"

    # Pre-provision backup if DB already has content (safety first)
    if [[ "$no_backup" == true ]]; then
        log warn "[PROV] Pre-provision backup skipped by flag (--no-backup)."
    else
        local table_count=""
        if table_count=$(db_table_count 2>/dev/null); then
            if [[ "$table_count" -gt 0 ]]; then
                log warn "[PROV] Existing tables detected ($table_count). Creating pre-provision DB backup."
                if ! provision_prebackup_db; then
                    log err "[PROV] Pre-provision backup failed; aborting to protect existing data."
                    return 1
                fi
            fi
        else
            log warn "[PROV] Could not determine table count; creating pre-provision DB backup to be safe."
            if ! provision_prebackup_db; then
                log err "[PROV] Pre-provision backup failed; aborting to protect existing data."
                return 1
            fi
        fi
    fi

    if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
        run_artisan migrate:fresh --seed --force || {
            log err "[PROV] Failed to migrate and seed"
            return 1
        }
        run_artisan ninja:translations || log warn "[PROV] Translation download failed; language list may be incomplete."
    else
        run_artisan migrate:fresh --seed --force >/dev/null 2>&1 || {
            log err "[PROV] Failed to migrate and seed"
            return 1
        }
        run_artisan ninja:translations >/dev/null 2>&1 || log warn "[PROV] Translation download failed; language list may be incomplete."
    fi
    local seeder=""
    if [ -f "${INM_INSTALLATION_PATH%/}/database/seeders/LanguageSeeder.php" ]; then
        seeder="LanguageSeeder"
    elif [ -f "${INM_INSTALLATION_PATH%/}/database/seeders/LanguagesSeeder.php" ]; then
        seeder="LanguagesSeeder"
    else
        seeder="LanguageSeeder"
    fi
    if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
        run_artisan db:seed --class="$seeder" --force || {
            if [ "$seeder" != "LanguagesSeeder" ]; then
                run_artisan db:seed --class=LanguagesSeeder --force || \
                    log warn "[PROV] Language seeder failed; language list may be incomplete."
            else
                log warn "[PROV] Language seeder failed; language list may be incomplete."
            fi
        }
    elif ! run_artisan db:seed --class="$seeder" --force >/dev/null 2>&1; then
        if [ "$seeder" != "LanguagesSeeder" ]; then
            run_artisan db:seed --class=LanguagesSeeder --force >/dev/null 2>&1 || \
                log warn "[PROV] Language seeder failed; language list may be incomplete."
        else
            log warn "[PROV] Language seeder failed; language list may be incomplete."
        fi
    fi
    if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
        run_artisan ninja:post-update || log warn "[PROV] artisan post-update failed"
    else
        run_artisan ninja:post-update >/dev/null 2>&1 || log warn "[PROV] artisan post-update failed"
    fi
        if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
            run_artisan ninja:create-account --email=admin@admin.com --password=admin || {
                log err "[PROV] Failed to create default user"
                return 1
            }
        elif ! run_artisan ninja:create-account --email=admin@admin.com --password=admin >/dev/null 2>&1; then
            log err "[PROV] Failed to create default user"
            return 1
        fi
        if true; then
            local cron_jobs="${NAMED_ARGS[cron_jobs]:-${NAMED_ARGS[cron-jobs]:-both}}"
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
            log debug "[PROV] Cron install skipped by flag (--no-cron-install)."
            cron_ok=false
            cron_skipped=true
            else
                if ! install_cronjob "user=$cron_user" "jobs=$cron_jobs" "mode=$cron_mode" "backup_time=$backup_time"; then
                    cron_ok=false
                fi
            fi
            if [ -f "${INM_ENV_FILE:-}" ]; then
                load_env_file_raw "$INM_ENV_FILE" || log warn "[PROV] Failed to load app env for summary."
            fi
            print_provisioned_summary "$cron_ok" "$cron_jobs" "$cron_skipped"
        fi
    return 0
}

# ---------------------------------------------------------------------
# provision_prebackup_db()
# Creates a DB-only backup before destructive provisioning steps.
# ---------------------------------------------------------------------
provision_prebackup_db() {
    # Hydrate DB vars from app env if not set
    if { [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_HOST:-}" ] || [ -z "${DB_DATABASE:-}" ]; } && [ -f "${INM_ENV_FILE:-}" ]; then
        log debug "[PROV] Loading DB vars from app env: $INM_ENV_FILE"
        if ! load_env_file_raw "$INM_ENV_FILE"; then
            log warn "[PROV] Failed to parse app env: $INM_ENV_FILE"
        fi
    fi

    if [[ -z "${DB_DATABASE:-}" || -z "${DB_USERNAME:-}" ]]; then
        log err "[PROV] Missing DB_DATABASE/DB_USERNAME; cannot create pre-provision backup."
        return 1
    fi

    local backup_dir="${INM_BACKUP_DIRECTORY:-./.backups}"
    mkdir -p "$backup_dir" 2>/dev/null || {
        log err "[PROV] Cannot create backup directory: $backup_dir"
        return 1
    }

    local target_file="${backup_dir%/}/${DB_DATABASE}_preprovision_$(date +%Y%m%d-%H%M%S).sql"
    log debug "[PROV] Creating pre-provision DB backup: $target_file"
    if ! INM_QUIET_DUMP=true dump_database "$target_file"; then
        log err "[PROV] Pre-provision backup failed: $target_file"
        return 1
    fi
    log debug "[PROV] Pre-provision backup saved: $target_file"
    if declare -F enforce_ownership >/dev/null 2>&1; then
        enforce_ownership "$backup_dir"
    fi
    if declare -F cleanup_old_backups >/dev/null 2>&1; then
        cleanup_old_backups || log warn "[PROV] Backup cleanup failed."
    fi
    return 0
}

# ---------------------------------------------------------------------
# provision_prepare_database()
# Ensures target DB exists before migration/restore in provisioned installs.
# Uses DB_ELEVATED_* if present; prompts otherwise.
# ---------------------------------------------------------------------
provision_prepare_database() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would prepare/create database; skipping."
        return 0
    fi
    # Load app env to hydrate DB_* vars if not already set
    if [ -f "${INM_ENV_FILE:-}" ]; then
        if ! load_env_file_raw "${INM_ENV_FILE}"; then
            log warn "[PROV] Failed to parse app env: ${INM_ENV_FILE}"
        fi
    fi

    local db_name="${DB_DATABASE:-}"
    local db_user="${DB_USERNAME:-}"
    local db_pass="${DB_PASSWORD:-}"
    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-3306}"
    local elev_user="${DB_ELEVATED_USERNAME:-}"
    local elev_pass="${DB_ELEVATED_PASSWORD:-}"

    if [[ -z "$db_name" || -z "$db_user" ]]; then
        log warn "[PROV] Missing DB_DATABASE/DB_USERNAME; cannot auto-create DB."
        return 0
    fi

    # Check if DB already exists
    local check_cmd=("mysql" "-h" "$db_host" "-P" "$db_port" "-u" "${db_user}")
    [[ -n "$db_pass" ]] && check_cmd+=("-p${db_pass}")
    if "${check_cmd[@]}" -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_name}'" >/dev/null 2>&1; then
        log debug "[PROV] Database '${db_name}' already exists."
        return 0
    fi

    # Need elevated creds to create DB/user
    if [[ -z "$elev_user" ]]; then
        elev_user=$(prompt_var "DB_ELEVATED_USERNAME" "root" "[PROV] Elevated MySQL user to create DB/user:" false 60) || return 1
    fi
    if [[ -z "$elev_pass" ]]; then
        elev_pass=$(prompt_var "DB_ELEVATED_PASSWORD" "" "[PROV] Password for ${elev_user} (leave blank if none):" true 60) || return 1
    fi

    log info "[PROV] Creating database '${db_name}' and user '${db_user}' (host ${db_host}:${db_port})"
    NAMED_ARGS[db_host]="$db_host"
    NAMED_ARGS[db_port]="$db_port"
    NAMED_ARGS[db_name]="$db_name"
    NAMED_ARGS[db_user]="$db_user"
    NAMED_ARGS[db_pass]="$db_pass"
    create_database "$elev_user" "$elev_pass"
}
