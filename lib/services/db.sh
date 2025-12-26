#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_DB_LOADED:-} ]] && return
__SERVICE_DB_LOADED=1

# ---------------------------------------------------------------------
# detect_mysql_collation()
# ---------------------------------------------------------------------
detect_mysql_collation() {
    local collation="${1:-}"
    local db_client="${2:-}"
    if [ -n "$collation" ]; then
        echo "$collation"
        return 0
    fi

    if [ -z "$db_client" ]; then
        db_client="$(select_db_client false true)"
    fi
    if [ -n "$db_client" ] && "$db_client" --version 2>/dev/null | grep -iq "mariadb"; then
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

    if [[ "$force" != true ]]; then
        log err "[import_db] Import is destructive. Re-run with --force to proceed."
        return 1
    fi

    # Hydrate DB vars from app env if not set
    if { [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_HOST:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_PASSWORD:-}" ]; } && [ -f "${INM_ENV_FILE:-}" ]; then
        log debug "[import_db] Loading DB vars from app env: ${INM_ENV_FILE}"
        set -a
        # shellcheck disable=SC1090
        . "${INM_ENV_FILE}"
        set +a
    fi
    local db_config_present=false
    if [[ -n "${DB_HOST:-}" || -n "${DB_USERNAME:-}" || -n "${DB_DATABASE:-}" ]]; then
        db_config_present=true
    fi

    # Prompt if still missing essentials
    if [[ -z "${DB_USERNAME:-}" ]]; then
        DB_USERNAME=$(prompt_var "MYSQL_USER" "root" "MySQL/MariaDB user for import:" false 60) || return 1
    fi
    if [[ -z "${DB_DATABASE:-}" ]]; then
        DB_DATABASE=$(prompt_var "MYSQL_DB" "" "MySQL/MariaDB database to import into:" false 60) || return 1
    fi
    if [[ -z "${DB_HOST:-}" ]]; then
        DB_HOST=$(prompt_var "MYSQL_HOST" "localhost" "MySQL/MariaDB host:" false 60) || return 1
    fi
    if [[ -z "${DB_PASSWORD:-}" && "${INM_FORCE_READ_DB_PW^^}" == "Y" ]]; then
        DB_PASSWORD=$(prompt_var "MYSQL_PASS" "" "Password for ${DB_USERNAME}:" true 60) || return 1
    fi

    if [[ -z "$file" ]]; then
        log err "[import_db] No SQL file provided. Use --file=/path/to/dump.sql"
        exit 1
    fi

    if [[ ! -f "$file" ]]; then
        log err "[import_db] File not found: $file"
        exit 1
    fi

    local db_client=""
    db_client="$(select_db_client true "$db_config_present")"
    if [ -z "$db_client" ]; then
        log err "[import_db] No MySQL/MariaDB client found. Please install mysql or mariadb client tools."
        exit 1
    fi

    local db_cmd=("$db_client" "-u${DB_USERNAME}" "-h${DB_HOST}" "-P${DB_PORT:-3306}")
    [[ -n "${DB_PASSWORD:-}" ]] && db_cmd+=("-p${DB_PASSWORD}")

    # Connectivity check; if it fails, prompt for elevated creds (e.g., root)
    if ! "${db_cmd[@]}" -e "SELECT 1" >/dev/null 2>&1; then
        log warn "[import_db] Initial DB credentials failed; prompting for elevated DB user."
        local elev_user elev_pw
        elev_user=$(prompt_var "MYSQL_USER" "${DB_USERNAME:-root}" "MySQL/MariaDB user for import (e.g., root):" false 60) || return 1
        elev_pw=$(prompt_var "MYSQL_PASS" "" "Password for ${elev_user} (leave blank if none):" true 60) || return 1
        db_cmd=("$db_client" "-u${elev_user}" "-h${DB_HOST}" "-P${DB_PORT:-3306}")
        [[ -n "$elev_pw" ]] && db_cmd+=("-p${elev_pw}")
        # Persist for later calls in this function
        DB_USERNAME="$elev_user"
        DB_PASSWORD="$elev_pw"
        if ! "${db_cmd[@]}" -e "SELECT 1" >/dev/null 2>&1; then
            # Try socket if host is localhost
            if [[ "${DB_HOST}" == "localhost" || "${DB_HOST}" == "127.0.0.1" ]]; then
                db_cmd=("$db_client" "-u${elev_user}" "-S" "${DB_SOCKET:-/var/run/mysqld/mysqld.sock}")
                [[ -n "$elev_pw" ]] && db_cmd+=("-p${elev_pw}")
                if "${db_cmd[@]}" -e "SELECT 1" >/dev/null 2>&1; then
                    log ok "[import_db] Elevated DB credentials accepted via socket."
                else
                    log err "[import_db] Could not connect with provided elevated credentials (host or socket)."
                    return 1
                fi
            else
                log err "[import_db] Could not connect with provided elevated credentials."
                return 1
            fi
        else
            log ok "[import_db] Elevated DB credentials accepted."
        fi
    fi

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

    # Detect existing tables; purge by default to avoid mixed data
    local table_count=""
    if table_count=$("${db_cmd[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_DATABASE}'" 2>/dev/null); then
        if [[ "$table_count" -gt 0 && "$purge" != false ]]; then
            log warn "[import_db] Purging database '$DB_DATABASE' (drop/create) before import; existing tables: $table_count."
            local collation
            collation=$(detect_mysql_collation "${DB_COLLATION:-}" "$db_client")
            if ! "${db_cmd[@]}" -e "DROP DATABASE IF EXISTS \`$DB_DATABASE\`; CREATE DATABASE \`$DB_DATABASE\` DEFAULT COLLATE $collation;" ; then
                log err "[import_db] Purge failed (drop/create)."
                [[ "$force" == true ]] && log warn "[import_db] Continuing import despite purge failure due to --force." || return 1
            fi
        elif [[ "$table_count" -gt 0 ]]; then
            log warn "[import_db] Existing tables detected ($table_count) and --purge=false; import may overwrite data."
        fi
    else
        log warn "[import_db] Could not determine existing tables (permissions?). Proceeding with import."
    fi

    log info "[import_db] Importing '$file' into database '$DB_DATABASE' ..."
    if ! "${db_cmd[@]}" "$DB_DATABASE" < "$file"; then
        log err "[import_db] Import failed for $DB_DATABASE@$DB_HOST."
        exit 1
    fi

    log ok "[import_db] Import completed."
}

# ---------------------------------------------------------------------
# db_table_count()
# Returns the number of tables in the current DB. Prints count on success.
# ---------------------------------------------------------------------
db_table_count() {
    # Hydrate DB vars from app env if not set
    if { [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_HOST:-}" ] || [ -z "${DB_DATABASE:-}" ]; } && [ -f "${INM_ENV_FILE:-}" ]; then
        log debug "[db_count] Loading DB vars from app env: $INM_ENV_FILE"
        set -a
        # shellcheck disable=SC1090
        . "$INM_ENV_FILE"
        set +a
    fi

    if [[ -z "${DB_DATABASE:-}" || -z "${DB_USERNAME:-}" ]]; then
        log warn "[db_count] Missing DB_DATABASE/DB_USERNAME; cannot count tables."
        return 1
    fi

    local db_client=""
    db_client="$(select_db_client false true)"
    if [[ -z "$db_client" ]]; then
        log err "[db_count] No MySQL/MariaDB client found."
        return 1
    fi

    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-3306}"
    local db_cmd=("$db_client" "-h" "$db_host" "-P" "$db_port" "-u" "$DB_USERNAME")
    [[ -n "${DB_PASSWORD:-}" ]] && db_cmd+=("-p$DB_PASSWORD")

    local table_count=""
    if table_count=$("${db_cmd[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_DATABASE}'" 2>/dev/null); then
        printf "%s" "$table_count"
        return 0
    fi

    log warn "[db_count] Could not determine table count (permissions?)."
    return 1
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

    local db_client=""
    local db_dump=""
    db_client="$(select_db_client false true)"
    db_dump="$(select_db_dump "$db_client")"
    if [ -z "$db_dump" ]; then
        log err "[dump_db] No MySQL/MariaDB dump tool found. Please install mysqldump or mariadb-dump."
        return 1
    fi

    local dump_cmd=("$db_dump")
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
    else

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
                log err "[dump_db] Dump failed for ${DB_DATABASE}@${DB_HOST} (${db_dump} exit $(cat _dump.err))"
            log err "[dump_db] Dump failed for ${DB_DATABASE}@${DB_HOST}. ${db_dump} output:"
            cat _dump.err >&2
                rm -f _dump.err
                return 1
            fi
        else
            rm -f _dump.err
    fi

    fi

    # Sanitize dump for portability: strip hardcoded DEFINERs
    if command -v sed >/dev/null 2>&1; then
        local tmp_sanitize
        tmp_sanitize=$(mktemp) || true
        if [[ -n "$tmp_sanitize" ]]; then
            if sed -E 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' "$target_file" > "$tmp_sanitize"; then
                mv "$tmp_sanitize" "$target_file"
                log debug "[dump_db] Sanitized dump (DEFINER replaced with CURRENT_USER)."
            else
                rm -f "$tmp_sanitize"
            fi
        fi
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

    local db_client=""
    db_client="$(select_db_client false true)"
    if [ -z "$db_client" ]; then
        log err "[db] No MySQL/MariaDB client found. Please install mysql or mariadb client tools."
        exit 1
    fi

    local collation
    collation=$(detect_mysql_collation "${DB_COLLATION:-}" "$db_client")

    local db_host="${NAMED_ARGS[db_host]:-${DB_HOST:-localhost}}"
    local db_port="${NAMED_ARGS[db_port]:-${DB_PORT:-3306}}"
    local db_name="${NAMED_ARGS[db_name]:-$DB_DATABASE}"
    local db_user="${NAMED_ARGS[db_user]:-$DB_USERNAME}"
    local db_pass="${NAMED_ARGS[db_pass]:-$DB_PASSWORD}"

    log debug "[db] Running DB provisioning commands..."
    if "$db_client" -h "$db_host" -P "$db_port" -u "$elevated_user" -p"$elevated_pass" <<EOF
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
