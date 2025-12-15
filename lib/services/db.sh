#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_DB_LOADED:-} ]] && return
__SERVICE_DB_LOADED=1

# ---------------------------------------------------------------------
# detect_mysql_collation()
# ---------------------------------------------------------------------
detect_mysql_collation() {
    local collation="${1:-}"
    if [ -n "$collation" ]; then
        echo "$collation"
        return 0
    fi

    if mysql --version 2>/dev/null | grep -iq "mariadb"; then
        echo "utf8mb4_unicode_ci"
    else
        echo "utf8mb4_unicode_ci"
    fi
}

# ---------------------------------------------------------------------
# import_database()
# ---------------------------------------------------------------------
import_database() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping DB restore/import."
        return 0
    fi
    log debug "[import_db] Starting import ..."

    local -A ARGS
    parse_named_args ARGS "$@"

    local file="${ARGS[file]:-}"
    local force="${ARGS[force]:-${force_update:-false}}"
    local purge="${ARGS[purge_before_import]:-${ARGS[purge]:-true}}"
    local prebackup="${ARGS[pre_backup]:-${ARGS[pre-backup]:-true}}"

    if [[ -z "$file" ]]; then
        log err "[import_db] No SQL file provided. Use --file=/path/to/dump.sql"
        exit 1
    fi

    if [[ ! -f "$file" ]]; then
        log err "[import_db] File not found: $file"
        exit 1
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        log err "[import_db] mysql client not found. Please install MySQL client tools."
        exit 1
    fi

    local mysql_cmd=("mysql" "-u${DB_USERNAME}" "-h${DB_HOST}" "-P${DB_PORT:-3306}")
    [[ "$INM_FORCE_READ_DB_PW" == "Y" ]] && mysql_cmd+=("-p${DB_PASSWORD}")

    # Always attempt a pre-backup unless explicitly skipped
    if [[ "$prebackup" != false ]]; then
        local backup_dir="${INM_BACKUP_DIRECTORY:-./_backups}"
        mkdir -p "$backup_dir" 2>/dev/null || log warn "[import_db] Could not ensure backup dir $backup_dir"
        if [[ -d "$backup_dir" ]]; then
            local shadow_dump="$backup_dir/${DB_DATABASE}_preimport_$(date +%Y%m%d-%H%M%S).sql"
            log info "[import_db] Creating pre-import backup: $shadow_dump"
            if ! dump_database "$shadow_dump"; then
                log err "[import_db] Pre-import backup failed; aborting import. Use --pre-backup=false to skip (not recommended)."
                return 1
            fi
            log ok "[import_db] Pre-import backup saved to $shadow_dump"
        else
            log err "[import_db] Backup directory unavailable; aborting import. Use --pre-backup=false to override."
            return 1
        fi
    else
        log warn "[import_db] Pre-import backup skipped by flag (not recommended)."
    fi

    # Detect existing tables and warn before overwrite (unless forced)
    local table_count=""
    if table_count=$("${mysql_cmd[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_DATABASE}'" 2>/dev/null); then
        if [[ "$table_count" -gt 0 && "$force" != true ]]; then
            log warn "[import_db] Database '$DB_DATABASE' already has $table_count tables. Import will overwrite data."
            local answer
            answer=$(prompt_var "CONFIRM_IMPORT" "no" "Proceed with import and overwrite existing data? (yes/no)" false 60) || exit 1
            if [[ ! "$answer" =~ ^([Yy]([Ee][Ss])?|[Jj][Aa])$ ]]; then
                log info "[import_db] Import cancelled by user."
                return 0
            fi
        fi

        # Optional purge before import (default true)
        if [[ "$purge" == true ]]; then
            log warn "[import_db] Purging database '$DB_DATABASE' before import."
            local collation
            collation=$(detect_mysql_collation "${DB_COLLATION:-}")
            if ! "${mysql_cmd[@]}" -e "DROP DATABASE IF EXISTS \`$DB_DATABASE\`; CREATE DATABASE \`$DB_DATABASE\` DEFAULT COLLATE $collation;" ; then
                log err "[import_db] Purge failed (drop/create)."
                [[ "$force" == true ]] && log warn "[import_db] Continuing import despite purge failure due to --force." || return 1
            fi
        fi
    else
        log warn "[import_db] Could not determine existing tables (permissions?). Proceeding with import."
    fi

    log info "[import_db] Importing '$file' into database '$DB_DATABASE' ..."
    if ! "${mysql_cmd[@]}" "$DB_DATABASE" < "$file"; then
        log err "[import_db] Import failed for $DB_DATABASE@$DB_HOST."
        exit 1
    fi

    log ok "[import_db] Import completed."
}

# ---------------------------------------------------------------------
# dump_database()
# Creates a database dump to the given target file, honoring .my.cnf or
# prompting for password when needed.
# ---------------------------------------------------------------------
dump_database() {
    local target_file="$1"
    [[ -z "$target_file" ]] && { log err "[dump_db] No target file provided."; return 1; }

    # Hydrate DB vars from app env if not set
    if { [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_HOST:-}" ] || [ -z "${DB_DATABASE:-}" ]; } && [ -f "${INM_ENV_FILE:-}" ]; then
        log debug "[dump_db] Loading DB vars from app env: $INM_ENV_FILE"
        set -a
        # shellcheck disable=SC1090
        . "$INM_ENV_FILE"
        set +a
    fi

    log info "[dump_db] Dumping database to $target_file ..."

    if ! command -v mysqldump >/dev/null 2>&1; then
        log err "[dump_db] mysqldump not found. Please install the MySQL client tools."
        return 1
    fi

    local dump_cmd=("mysqldump")
    if [[ -n "$INM_DUMP_OPTIONS" ]]; then
        read -r -a tmp_opts <<< "$INM_DUMP_OPTIONS"
        dump_cmd+=("${tmp_opts[@]}")
    fi

    dump_cmd+=("-u$DB_USERNAME" "-h$DB_HOST" "$DB_DATABASE")
    log debug "[dump_db] Command: ${dump_cmd[*]/$DB_PASSWORD/******}"

    if [[ "${INM_FORCE_READ_DB_PW^^}" == "Y" ]]; then
        if [[ -z "${DB_PASSWORD:-}" ]]; then
            log err "[dump_db] INM_FORCE_READ_DB_PW=Y but DB_PASSWORD is empty; cannot proceed without prompting."
            return 1
        fi
        log debug "[dump_db] INM_FORCE_READ_DB_PW=Y → Using .env password (no prompt)"
        dump_cmd+=("-p$DB_PASSWORD")
        if ! "${dump_cmd[@]}" > "$target_file"; then
            log err "[dump_db] Database dump failed using .env password"
            return 1
        fi
        log ok "[dump_db] Database dumped (using env password)."
        return 0
    fi

    log debug "[dump_db] INM_FORCE_READ_DB_PW≠Y → Attempt .my.cnf"
        if ! "${dump_cmd[@]}" > "$target_file" 2>_dump.err; then
            if grep -qi "Access denied" _dump.err; then
                log warn "[dump_db] .my.cnf failed – prompting for password"
                local success=false
                for attempt in {1..3}; do
                    DB_PASSWORD=$(prompt_var DB_PASSWORD "" \
                    "Enter database password (user: ${DB_USERNAME:-<unset>})" true 60) || {
                    log err "[dump_db] No password entered – aborting"
                    break
                }
                dump_cmd=("${dump_cmd[@]/-u$DB_USERNAME/-u$DB_USERNAME -p$DB_PASSWORD}")
                if "${dump_cmd[@]}" > "$target_file"; then
                    success=true
                    break
                else
                    log warn "[dump_db] Dump failed (attempt $attempt)"
                fi
            done
                rm -f _dump.err
                [[ "$success" != true ]] && return 1
            else
                log err "[dump_db] Dump failed for ${DB_DATABASE}@${DB_HOST} (mysqldump exit $(cat _dump.err))"
            log err "[dump_db] Dump failed for ${DB_DATABASE}@${DB_HOST}. mysqldump output:"
            cat _dump.err >&2
                rm -f _dump.err
                return 1
            fi
        else
            rm -f _dump.err
    fi

    log ok "[dump_db] Database dumped: $target_file"
    return 0
}

# ---------------------------------------------------------------------
# create_database()
# ---------------------------------------------------------------------
create_database() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping DB create."
        return 0
    fi
    local elevated_user="$1"
    local elevated_pass="$2"

    local collation
    collation=$(detect_mysql_collation "${DB_COLLATION:-}")

    local db_host="${NAMED_ARGS[db_host]:-${DB_HOST:-localhost}}"
    local db_port="${NAMED_ARGS[db_port]:-${DB_PORT:-3306}}"
    local db_name="${NAMED_ARGS[db_name]:-$DB_DATABASE}"
    local db_user="${NAMED_ARGS[db_user]:-$DB_USERNAME}"
    local db_pass="${NAMED_ARGS[db_pass]:-$DB_PASSWORD}"

    log debug "[db] Running DB provisioning commands..."
    if mysql -h "$db_host" -P "$db_port" -u "$elevated_user" -p"$elevated_pass" <<EOF
CREATE DATABASE IF NOT EXISTS \`$db_name\` DEFAULT COLLATE $collation;

CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '${db_pass//\'/\\\'}';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost' WITH GRANT OPTION;

CREATE USER IF NOT EXISTS '$db_user'@'$db_host' IDENTIFIED BY '${db_pass//\'/\\\'}';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'$db_host' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOF
    then
        log ok "[db] Database and user created successfully."
        if [ -f "$INM_PROVISION_ENV_FILE" ]; then
            sed -i '/^DB_ELEVATED_USERNAME/d' "$INM_PROVISION_ENV_FILE"
            sed -i '/^DB_ELEVATED_PASSWORD/d' "$INM_PROVISION_ENV_FILE"
            log info "[db] Removed elevated credentials from provision file."
        fi
    else
        log err "[db] Database creation failed."
        exit 1
    fi
}
