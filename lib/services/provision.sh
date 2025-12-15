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
# Creates/updates .env.provision based on current app env or bundled example.
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

    mkdir -p "$(dirname "$target")" 2>/dev/null || {
        log err "[PROV] Cannot create directory for provision file: $(dirname "$target")"
        return 1
    }

    if [ -f "$target" ] && [ "$force" != true ]; then
        log warn "[PROV] Provision file exists: $target (use --force to overwrite)."
        return 0
    fi

    local src_env=""
    if [ -f "${INM_ENV_FILE:-}" ]; then
        src_env="$INM_ENV_FILE"
        log info "[PROV] Seeding from app env: $src_env"
    elif [ -f "${SCRIPT_DIR:-.}/.env.example" ]; then
        src_env="${SCRIPT_DIR:-.}/.env.example"
        log info "[PROV] Seeding from bundled .env.example: $src_env"
    fi

    local keys=(APP_NAME APP_URL PDF_GENERATOR APP_DEBUG DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD DB_ELEVATED_USERNAME DB_ELEVATED_PASSWORD)
    {
        echo "# Auto-generated provision file"
        echo "# Adjust values as needed, then run: inmanage core install --provision"
        echo "# Generated: $(date -Iseconds)"
        for k in "${keys[@]}"; do
            local v=""
            if [ -n "$src_env" ]; then
                v=$(grep -E "^${k}=" "$src_env" 2>/dev/null | tail -n1 | cut -d= -f2-)
            fi
            printf "%s=%s\n" "$k" "${v}"
        done
        if [ -n "$migration_backup" ]; then
            printf "INM_MIGRATION_BACKUP=%s\n" "$migration_backup"
            log info "[PROV] Added migration backup reference: $migration_backup"
        elif [ "$latest_backup" = true ]; then
            printf "INM_MIGRATION_BACKUP=LATEST\n"
            log info "[PROV] Will use latest backup during provisioned install."
        fi
    } > "$target"

    chmod 600 "$target" 2>/dev/null || true
    log ok "[PROV] Provision file written: $target"
}

# ---------------------------------------------------------------------
# provision_post_install()
# Runs provision-specific post steps (migrate/seed, create admin, messages).
# ---------------------------------------------------------------------
provision_post_install() {
    log info "[PROV] Running provisioned post-install steps"

    run_artisan migrate:fresh --seed --force || {
        log err "[PROV] Failed to migrate and seed"
        return 1
    }
    if run_artisan ninja:create-account --email=admin@admin.com --password=admin; then
        printf "\n${BLUE}%s${RESET}\n" "========================================"
        printf "${GREEN}${BOLD}Setup Complete!${RESET}\n\n"
        printf "${BOLD}Login:${RESET} ${CYAN}%s${RESET}\n" "$APP_URL"
        printf "${BOLD}Username:${RESET} admin@admin.com\n"
        printf "${BOLD}Password:${RESET} admin\n"
        printf "${BLUE}%s${RESET}\n\n" "========================================"
        printf "${WHITE}Open your browser at ${CYAN}%s${RESET} to access the application.${RESET}\n" "$APP_URL"
        printf "The database and user are configured.\n\n"
        printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
        printf "${BOLD}Cronjob Setup:${RESET}\n"
        printf "  ${CYAN}* * * * * %s %s schedule:run >> /dev/null 2>&1${RESET}\n" "$INM_ENFORCED_USER" "$(artisan_cmd_string)"
        printf "  ${CYAN}* 3 * * * %s %s -c \"%s./inmanage.sh backup\" >> /dev/null 2>&1${RESET}\n\n" "$INM_ENFORCED_USER" "$INM_ENFORCED_SHELL" "$INM_BASE_DIRECTORY"
        printf "${BOLD}To install cronjobs automatically, use:${RESET}\n"
        printf "  ${CYAN}./inmanage.sh install_cronjob user=%s jobs=both${RESET}\n" "$INM_ENFORCED_USER"
        printf "  Full explanation available via ${CYAN}./inmanage.sh -h${RESET}\n\n"
    else
        log err "[PROV] Failed to create default user"
        return 1
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
        set -a
        # shellcheck disable=SC1090
        . "${INM_ENV_FILE}"
        set +a
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
