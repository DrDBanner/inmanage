#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_PROVISION_LOADED:-} ]] && return
__SERVICE_PROVISION_LOADED=1

# ---------------------------------------------------------------------
# spawn_provision_file()
# Creates/updates .env.provision based on .env.example (preferred) or app env.
# Supports: --provision-file, --backup-file, --latest-backup, --force.
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# spawn_provision_file()
# Create a provision file template for Invoice Ninja + INmanage.
# Consumes: env: INM_PROVISION_ENV_FILE, INM_BASE_DIRECTORY; globals: NAMED_ARGS.
# Computes: provision file content.
# Returns: 0 on success, non-zero on failure.
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
    assert_file_path "$target" "Provision file path" || return 1

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
        local env_example_contents=""
        local -a auth_args=()
        gh_auth_args auth_args
        if http_fetch_with_args "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" \
            env_example_contents false -L "${auth_args[@]}"; then
            printf "%s" "$env_example_contents" > "$env_example"
        else
            log warn "[PROV] Failed to download .env.example; will try app env instead."
            env_example=""
        fi
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

    # Remove duplicate elevated DB entries if present (keep first occurrence).
    local tmp_dedup="${target}.dedup.$$"
    awk '
        BEGIN {u=0; p=0}
        /^DB_ELEVATED_USERNAME=/ {
            if (u==0) {u=1; print}
            next
        }
        /^DB_ELEVATED_PASSWORD=/ {
            if (p==0) {p=1; print}
            next
        }
        {print}
    ' "$target" > "$tmp_dedup" 2>/dev/null && mv "$tmp_dedup" "$target"

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
# apply_inm_keys_from_provision()
# Copy INM_* keys from provision file into CLI config.
# Consumes: args: provision_file; env: INM_SELF_ENV_FILE; deps: env_set.
# Computes: CLI config updates.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
apply_inm_keys_from_provision() {
    local provision_file="$1"
    if [ -z "$provision_file" ] || [ ! -f "$provision_file" ]; then
        return 0
    fi
    if [ -z "${INM_SELF_ENV_FILE:-}" ] || [ ! -f "${INM_SELF_ENV_FILE:-}" ]; then
        log warn "[PROV] CLI config not found; skipping INM_* keys from provision file."
        return 0
    fi

    local count=0
    local line trimmed key raw val sensitive
    local -a applied_keys=()
    local -A seen_keys=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" =~ ^# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(INM_[A-Za-z0-9_]+)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[2]}"
            raw="${BASH_REMATCH[3]}"
            sensitive=false
            if _env_key_is_sensitive "$key"; then
                sensitive=true
            fi
            val="$(_env_parse_env_value "$raw" "$sensitive")"
            if env_set cli "${key}=${val}" >/dev/null 2>&1; then
                count=$((count + 1))
                if [[ -z "${seen_keys[$key]:-}" ]]; then
                    seen_keys["$key"]=1
                    applied_keys+=("$key")
                fi
            else
                log warn "[PROV] Failed to set ${key} in CLI config."
            fi
        fi
    done < "$provision_file"

    if [ "$count" -gt 0 ]; then
        local keys_display=""
        local max_keys=10
        local i
        for ((i=0; i<${#applied_keys[@]} && i<max_keys; i++)); do
            keys_display+="${keys_display:+, }${applied_keys[i]}"
        done
        if [ "${#applied_keys[@]}" -gt "$max_keys" ]; then
            keys_display+=", +$(( ${#applied_keys[@]} - max_keys )) more"
        fi
        log info "[PROV] Applied ${count} INM_* keys from provision file to CLI config (${keys_display})."
        load_env_file_raw "$INM_SELF_ENV_FILE" || true
    fi
}

# ---------------------------------------------------------------------
# maybe_setup_heartbeat_notifications()
# Applies notify defaults when heartbeat cron is installed.
# Runs a notify test if configuration looks complete.
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# maybe_setup_heartbeat_notifications()
# Enable heartbeat notification config when provision data is complete.
# Consumes: env: INM_NOTIFY_*; deps: env_set/notify_send_test.
# Computes: heartbeat setup and optional test.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
maybe_setup_heartbeat_notifications() {
    local scope="${1:-install}"
    local jobs="${INM_CRON_INSTALLED_JOBS:-}"
    if [[ ",${jobs}," != *",heartbeat,"* ]]; then
        return 0
    fi
    if [ -z "${INM_SELF_ENV_FILE:-}" ] || [ ! -f "${INM_SELF_ENV_FILE:-}" ]; then
        log warn "[${scope}] Heartbeat cron installed but CLI config missing; cannot auto-configure notifications."
        return 0
    fi

    load_env_file_raw "$INM_SELF_ENV_FILE" || true

    local changed=false
    local heartbeat_enabled="${INM_NOTIFY_HEARTBEAT_ENABLED,,}"
    if [[ -z "${INM_NOTIFY_HEARTBEAT_ENABLED:-}" ]]; then
        env_set cli INM_NOTIFY_HEARTBEAT_ENABLED=true >/dev/null 2>&1 && changed=true
        heartbeat_enabled=true
    fi
    if [[ "$heartbeat_enabled" == "true" ]]; then
        if [[ "${INM_NOTIFY_ENABLED,,}" != "true" ]]; then
            env_set cli INM_NOTIFY_ENABLED=true >/dev/null 2>&1 && changed=true
        fi
        if [[ -z "${INM_NOTIFY_TARGETS:-}" ]]; then
            env_set cli INM_NOTIFY_TARGETS=email >/dev/null 2>&1 && changed=true
        fi
        if [[ -z "${INM_NOTIFY_HEARTBEAT_LEVEL:-}" ]]; then
            env_set cli INM_NOTIFY_HEARTBEAT_LEVEL=WARN >/dev/null 2>&1 && changed=true
        fi
    fi
    if [[ "$changed" == true ]]; then
        load_env_file_raw "$INM_SELF_ENV_FILE" || true
        log info "[${scope}] Heartbeat defaults applied (INM_NOTIFY_*)."
    fi

    local notify_enabled="${INM_NOTIFY_ENABLED,,}"
    heartbeat_enabled="${INM_NOTIFY_HEARTBEAT_ENABLED,,}"
    if [[ "$notify_enabled" != "true" || "$heartbeat_enabled" != "true" ]]; then
        log warn "[${scope}] Heartbeat cron installed but notifications are disabled (INM_NOTIFY_ENABLED/INM_NOTIFY_HEARTBEAT_ENABLED)."
        return 0
    fi

    local targets=""
    targets="$(notify_resolve_targets)"
    if [ -z "$targets" ]; then
        log warn "[${scope}] Notification targets are empty; skipping notify-test."
        return 0
    fi

    local want_email=false
    local want_webhook=false
    [[ ",${targets}," == *",email,"* ]] && want_email=true
    [[ ",${targets}," == *",webhook,"* ]] && want_webhook=true

    local can_test=false
    if [[ "$want_email" == true ]]; then
        if [ -f "${INM_ENV_FILE:-}" ]; then
            load_env_file_raw "$INM_ENV_FILE" || true
        fi
        local mailer="${MAIL_MAILER:-${MAIL_DRIVER:-}}"
        mailer="${mailer,,}"
        if [[ -n "$mailer" && "$mailer" != "smtp" ]]; then
            log warn "[${scope}] MAIL_MAILER is '${mailer}', SMTP required for notify-test."
        elif [[ -z "${MAIL_HOST:-}" || -z "${MAIL_FROM_ADDRESS:-}" ]]; then
            log warn "[${scope}] SMTP not configured (MAIL_HOST/MAIL_FROM_ADDRESS). Set in app .env or .env.provision."
        elif [[ -z "${INM_NOTIFY_EMAIL_TO:-}" ]]; then
            log warn "[${scope}] INM_NOTIFY_EMAIL_TO is empty; skipping email notify-test."
        else
            can_test=true
        fi
    fi

    if [[ "$want_webhook" == true ]]; then
        if [[ -z "${INM_NOTIFY_WEBHOOK_URL:-}" ]]; then
            log warn "[${scope}] INM_NOTIFY_WEBHOOK_URL is empty; skipping webhook notify-test."
        else
            can_test=true
        fi
    fi

    if [[ "$can_test" != true ]]; then
        return 0
    fi

    local -A saved_named=()
    local key
    if declare -p NAMED_ARGS >/dev/null 2>&1; then
        for key in "${!NAMED_ARGS[@]}"; do
            saved_named["$key"]="${NAMED_ARGS[$key]}"
        done
    fi
    declare -g -A NAMED_ARGS=()
    declare -g INM_NOTIFY_SENT=false
    if ! run_preflight --notify-test --no-cli-clear --format=compact; then
        if [[ "${INM_NOTIFY_SENT:-false}" == true ]]; then
            log info "[${scope}] notify-test sent; preflight reported issues."
        else
            log warn "[${scope}] notify-test failed; check SMTP/webhook settings."
        fi
    fi
    declare -g -A NAMED_ARGS=()
    for key in "${!saved_named[@]}"; do
        NAMED_ARGS["$key"]="${saved_named[$key]}"
    done
}

# ---------------------------------------------------------------------
# provision_post_install()
# Run post-install steps for provisioned installs.
# Consumes: env: INM_* and APP_*; deps: cron/install/db tasks.
# Computes: DB prep, cron install, notify test, preflight.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
provision_post_install() {
    log info "[PROV] Running provisioned post-install steps"

    local force="${NAMED_ARGS[force]:-${force_update:-false}}"
    local can_prompt=false
    [[ -t 0 && -t 1 ]] && can_prompt=true

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
            local cron_jobs
            cron_jobs="$(args_get - "essential" cron_jobs jobs)"
            local cron_jobs_set=false
            if [[ -n "${NAMED_ARGS[cron_jobs]:-}" || -n "${NAMED_ARGS[jobs]:-}" ]]; then
                cron_jobs_set=true
            fi
            local cron_user="${INM_ENFORCED_USER:-$(whoami)}"
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
            local hb_enabled="${INM_NOTIFY_HEARTBEAT_ENABLED:-}"
            local hb_time="${INM_NOTIFY_HEARTBEAT_TIME:-}"
            local cfg_file=""
            local prov_file=""
            cfg_file="${INM_SELF_ENV_FILE:-}"
            prov_file="${INM_PROVISION_FILE_USED:-${INM_PROVISION_ENV_FILE:-}}"
            if [ -z "$cfg_file" ] && [ -n "${INM_BASE_DIRECTORY:-}" ]; then
                cfg_file="${INM_BASE_DIRECTORY%/}/.inmanage/.env.inmanage"
            fi
            if [ -z "$prov_file" ] && [ -n "${INM_BASE_DIRECTORY:-}" ]; then
                prov_file="${INM_BASE_DIRECTORY%/}/.inmanage/.env.provision"
            fi
            if [ -n "$cfg_file" ] && [[ "$cfg_file" != /* ]] && [ -n "${INM_BASE_DIRECTORY:-}" ]; then
                cfg_file="${INM_BASE_DIRECTORY%/}/${cfg_file#/}"
            fi
            if [ -n "$prov_file" ] && [[ "$prov_file" != /* ]] && [ -n "${INM_BASE_DIRECTORY:-}" ]; then
                prov_file="${INM_BASE_DIRECTORY%/}/${prov_file#/}"
            fi
            if [ -n "$cfg_file" ] && [ -f "$cfg_file" ]; then
                local hb_from_cfg
                local hb_time_from_cfg
                hb_from_cfg="$(read_env_value_safe "$cfg_file" "INM_NOTIFY_HEARTBEAT_ENABLED" 2>/dev/null)"
                hb_time_from_cfg="$(read_env_value_safe "$cfg_file" "INM_NOTIFY_HEARTBEAT_TIME" 2>/dev/null)"
                if [ -n "$hb_from_cfg" ]; then
                    hb_enabled="$hb_from_cfg"
                fi
                if [ -n "$hb_time_from_cfg" ]; then
                    hb_time="$hb_time_from_cfg"
                fi
            fi
            if [ -n "$prov_file" ] && [ -f "$prov_file" ]; then
                local hb_from_prov
                local hb_time_from_prov
                hb_from_prov="$(read_env_value_safe "$prov_file" "INM_NOTIFY_HEARTBEAT_ENABLED" 2>/dev/null)"
                hb_time_from_prov="$(read_env_value_safe "$prov_file" "INM_NOTIFY_HEARTBEAT_TIME" 2>/dev/null)"
                if [ -n "$hb_from_prov" ]; then
                    hb_enabled="$hb_from_prov"
                fi
                if [ -n "$hb_time_from_prov" ]; then
                    hb_time="$hb_time_from_prov"
                fi
            fi
            hb_enabled="${hb_enabled,,}"
            hb_enabled="${hb_enabled//[[:space:]]/}"
            log debug "[PROV] Cron select: cron_jobs=${cron_jobs} cron_jobs_set=${cron_jobs_set} hb_enabled=${hb_enabled:-<unset>} hb_time=${hb_time:-<unset>} cfg=${cfg_file:-<unset>} prov=${prov_file:-<unset>}"
            local heartbeat_time
            heartbeat_time="$(args_get - "${hb_time:-${INM_NOTIFY_HEARTBEAT_TIME:-06:00}}" heartbeat_time)"
            local cron_jobs_lc="${cron_jobs,,}"
            if args_is_true "$hb_enabled"; then
                if [[ ",${cron_jobs_lc}," != *",heartbeat,"* && ",${cron_jobs_lc}," != *",all,"* ]]; then
                    if [[ "$cron_jobs_set" == true ]]; then
                        log debug "[PROV] Heartbeat enabled but cron jobs set explicitly; leaving jobs as '${cron_jobs}'."
                    else
                        cron_jobs="${cron_jobs},heartbeat"
                    fi
                fi
            fi
            log debug "[PROV] Cron final: jobs=${cron_jobs}"
            if args_is_true "$no_backup_cron"; then
                cron_jobs="artisan"
            fi
            if args_is_true "$no_cron"; then
                log debug "[PROV] Cron install skipped by flag (--no-cron-install)."
                cron_ok=false
                cron_skipped=true
            else
                if ! install_cronjob "user=$cron_user" "jobs=$cron_jobs" "mode=$cron_mode" "backup_time=$backup_time" "heartbeat_time=$heartbeat_time"; then
                    cron_ok=false
                fi
            fi
            if [[ "$cron_ok" == true ]]; then
                maybe_setup_heartbeat_notifications "PROV"
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
# ---------------------------------------------------------------------
# provision_prebackup_db()
# Create a pre-provision database backup when needed.
# Consumes: env: INM_BACKUP_DIRECTORY, DB_*; deps: dump_database.
# Computes: pre-provision SQL dump.
# Returns: 0 on success, non-zero on failure.
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

    local target_file
    local ts="${INM_INSTALL_TIMESTAMP:-}"
    if [[ -z "$ts" && -n "${INM_INSTALL_ROLLBACK_DIR:-}" ]]; then
        local rb_base=""
        rb_base="$(basename "$INM_INSTALL_ROLLBACK_DIR")"
        if [[ "$rb_base" == *_rollback_* ]]; then
            ts="${rb_base##*_rollback_}"
        fi
    fi
    if [[ -z "$ts" ]]; then
        ts="$(date +%Y%m%d_%H%M%S)"
    fi
    INM_INSTALL_TIMESTAMP="$ts"
    target_file="${backup_dir%/}/${DB_DATABASE}_preprovision_${ts}.sql"
    log debug "[PROV] Creating pre-provision DB backup: $target_file"
    if ! INM_QUIET_DUMP=true dump_database "$target_file"; then
        log err "[PROV] Pre-provision backup failed: $target_file"
        return 1
    fi
    log debug "[PROV] Pre-provision backup saved: $target_file"
    enforce_ownership "$backup_dir"
    cleanup_old_backups || log warn "[PROV] Backup cleanup failed."
    return 0
}

# ---------------------------------------------------------------------
# provision_prepare_database()
# Ensures target DB exists before migration/restore in provisioned installs.
# Uses DB_ELEVATED_* if present; prompts otherwise.
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# provision_prepare_database()
# Prepare the database for provisioned installs.
# Consumes: env: DB_* and INM_*; deps: create_database/purge_database/import_database.
# Computes: DB creation or reset flow.
# Returns: 0 on success, non-zero on failure.
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
