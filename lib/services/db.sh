#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_DB_LOADED:-} ]] && return
__SERVICE_DB_LOADED=1

# ---------------------------------------------------------------------
# detect_mysql_collation()
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# detect_mysql_collation()
# Detect the default MySQL collation for the current connection.
# Consumes: args: db_client, db_host, db_port, db_user, db_pass.
# Computes: collation string from server.
# Returns: prints collation or empty string.
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
# db_emit_preflight()
# Emit database connectivity and schema info for preflight output.
# Consumes: args: add_fn, db_tag, app_tag; env: DB_*, INM_ENV_FILE/INM_INSTALLATION_PATH; deps: load_env_file_raw/select_db_client/expand_path_vars.
# Computes: connection status, server settings, language table info.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
db_emit_preflight() {
    local add_fn="$1"
    local db_tag="${2:-DB}"
    local app_tag="${3:-APP}"
    local emit_fn=""
    if trace_suspend_if_sensitive_key "DB_PASSWORD"; then
        trap 'trace_resume' RETURN
    fi
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    db_emit() {
        local status="$1"
        local tag="$2"
        local detail="$3"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "$tag" "$detail"
        else
            case "$status" in
                OK) log info "[${tag}] $detail" ;;
                WARN) log warn "[${tag}] $detail" ;;
                ERR) log err "[${tag}] $detail" ;;
                INFO) log info "[${tag}] $detail" ;;
                *) log info "[${tag}] $detail" ;;
            esac
        fi
    }

    # Try to hydrate DB vars from app env if missing
    local env_file="${INM_ENV_FILE:-}"
    if [ -z "$env_file" ] && [ -n "${INM_INSTALLATION_PATH:-}" ]; then
        env_file="${INM_INSTALLATION_PATH%/}/.env"
    fi
    if [ -z "${DB_HOST:-}" ] && [ -n "$env_file" ] && [ -f "$env_file" ]; then
        if load_env_file_raw "$env_file"; then
            db_emit INFO "$db_tag" "Loaded DB vars from ${env_file}"
        else
            db_emit WARN "$db_tag" "Failed to parse DB vars from ${env_file}"
        fi
    fi

    # ---- DB connectivity ----
    if [ -n "${DB_HOST:-}" ] && [ -n "${DB_USERNAME:-}" ]; then
        local db_port="${DB_PORT:-3306}"
        db_emit INFO "$db_tag" "Target: host=${DB_HOST} port=${db_port} db=${DB_DATABASE:-<unset>} user=${DB_USERNAME}"

        local db_client_local="${db_client:-}"
        if [ -z "$db_client_local" ]; then
            db_client_local="$(select_db_client false true)"
        fi
        if [ -z "$db_client_local" ]; then
            db_emit ERR "$db_tag" "No MySQL/MariaDB client available"
            return 0
        fi

        local -a db_cmd_base=("$db_client_local" -h "$DB_HOST" -P "$db_port" -u "$DB_USERNAME")
        if [ -n "${DB_PASSWORD:-}" ]; then
            db_cmd_base+=(-p"$DB_PASSWORD")
        fi
        if "${db_cmd_base[@]}" -e "SELECT 1" >/dev/null 2>&1; then
            db_emit INFO "$db_tag" "Client: ${db_client_local}"
            db_emit OK "$db_tag" "Connection ok to $DB_HOST:${db_port}"
            # Try to read server/version info
            local dbinfo
            dbinfo="$("${db_cmd_base[@]}" -N -e "select @@version, @@version_comment;" 2>/dev/null | head -n1)"
            if [ -n "$dbinfo" ]; then
                db_emit INFO "$db_tag" "Server: $dbinfo"
            fi
            # DB settings (best effort)
            local settings
            settings="$("${db_cmd_base[@]}" -N -e "select @@innodb_file_per_table, @@max_allowed_packet, @@character_set_server, @@collation_server;" 2>/dev/null | head -n1)"
            if [ -n "$settings" ]; then
                IFS=$'\t' read -r innodb packet charset coll <<<"$settings"
                db_emit INFO "$db_tag" "innodb_file_per_table=${innodb:-?}"
                db_emit INFO "$db_tag" "max_allowed_packet=${packet:-?}"
                db_emit INFO "$db_tag" "charset=${charset:-?} collation=${coll:-?}"
            fi
            local sql_mode
            sql_mode="$("${db_cmd_base[@]}" -N -e "select @@sql_mode;" 2>/dev/null | head -n1)"
            [[ -n "$sql_mode" ]] && db_emit INFO "$db_tag" "sql_mode=${sql_mode}"
            if [ -n "${DB_DATABASE:-}" ]; then
                if "${db_cmd_base[@]}" -e "USE \`$DB_DATABASE\`;" >/dev/null 2>&1; then
                    db_emit OK "$db_tag" "Database '$DB_DATABASE' exists."
                    local lang_table=""
                    if "${db_cmd_base[@]}" -N -B \
                        -e "SELECT table_name FROM information_schema.tables WHERE table_schema='${DB_DATABASE}' AND table_name='languages' LIMIT 1;" 2>/dev/null | grep -q "^languages$"; then
                        lang_table="languages"
                    elif "${db_cmd_base[@]}" -N -B \
                        -e "SELECT table_name FROM information_schema.tables WHERE table_schema='${DB_DATABASE}' AND table_name='language' LIMIT 1;" 2>/dev/null | grep -q "^language$"; then
                        lang_table="language"
                    fi

                    if [ -n "$lang_table" ]; then
                        local lang_count=""
                        lang_count="$("${db_cmd_base[@]}" -N -B \
                            -e "SELECT COUNT(*) FROM \`${DB_DATABASE}\`.\`${lang_table}\`;" 2>/dev/null | head -n1)"
                        if [[ "$lang_count" =~ ^[0-9]+$ ]]; then
                            if [ "$lang_count" -eq 0 ]; then
                                db_emit ERR "$app_tag" "Languages loaded: 0 (run ninja:translations + db:seed --class=LanguageSeeder)"
                            elif [ "$lang_count" -lt 10 ]; then
                                db_emit WARN "$app_tag" "Languages loaded: ${lang_count} (expected more; run ninja:translations + db:seed --class=LanguageSeeder)"
                            else
                                db_emit OK "$app_tag" "Languages loaded: ${lang_count}"
                            fi
                        else
                            db_emit WARN "$app_tag" "Languages count unavailable (query failed)"
                        fi
                    else
                        db_emit WARN "$app_tag" "Languages table missing; run migrations/seed (ninja:translations + db:seed --class=LanguageSeeder)"
                    fi
                else
                    local hint="Database '$DB_DATABASE' not found or no access."
                    hint+=" Set DB_ELEVATED_USERNAME/PASSWORD in .env.provision and rerun provision to create it."
                    db_emit WARN "$db_tag" "$hint"
                fi
            fi
        else
            local hint="Cannot connect to $DB_HOST:${db_port} as $DB_USERNAME"
            hint+=" (check DB_ELEVATED_USERNAME/PASSWORD or credentials in .env/.env.provision)"
            db_emit ERR "$db_tag" "$hint"
        fi
    else
        local db_env_file="${INM_ENV_FILE:-}"
        if [ -z "$db_env_file" ] && [ -n "${INM_INSTALLATION_PATH:-}" ]; then
            db_env_file="${INM_INSTALLATION_PATH%/}/.env"
        fi
        if [ -n "$db_env_file" ] && [ -f "$db_env_file" ]; then
            db_emit ERR "$db_tag" "Missing DB_HOST/DB_USERNAME despite loaded .env"
        else
            db_emit WARN "$db_tag" "DB config not set; skipping connectivity checks"
        fi
    fi
}

# ---------------------------------------------------------------------
# import_database()
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# import_database()
# Import a SQL file into the configured database.
# Consumes: args: file; env: DB_* and INM_*; deps: select_db_client.
# Computes: DB import using mysql client.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
import_database() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping DB restore/import."
        return 0
    fi
    if trace_suspend_if_sensitive_key "DB_PASSWORD"; then
        trap 'trace_resume' RETURN
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
    local env_file=""
    env_file="$(_db_env_file)"
    if { [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_HOST:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_PASSWORD:-}" ]; } && [ -n "$env_file" ] && [ -f "$env_file" ]; then
        log debug "[import_db] Loading DB vars from app env: ${env_file}"
        if ! load_env_file_raw "${env_file}"; then
            log warn "[import_db] Failed to parse app env: ${env_file}"
        fi
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
            local shadow_dump
            shadow_dump="$backup_dir/${DB_DATABASE}_preimport_$(date +%Y%m%d-%H%M%S).sql"
            log info "[import_db] Creating pre-import backup: $shadow_dump"
            if ! dump_database "$shadow_dump"; then
                log err "[import_db] Pre-import backup failed; aborting import. Use --pre-backup=false to skip (not recommended)."
                return 1
            fi
            log ok "[import_db] Pre-import backup saved to $shadow_dump"
            enforce_ownership "$backup_dir"
            cleanup_old_backups || log warn "[import_db] Backup cleanup failed."
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
# purge_database()
# Drops all tables/views in the current database without drop/create.
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# purge_database()
# Drop all tables from the configured database.
# Consumes: env: DB_* and INM_*; deps: select_db_client.
# Computes: DB table drops.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
purge_database() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping DB purge."
        return 0
    fi
    if trace_suspend_if_sensitive_key "DB_PASSWORD"; then
        trap 'trace_resume' RETURN
    fi

    local -A ARGS
    parse_named_args ARGS "$@"

    local force="${ARGS[force]:-${force_update:-false}}"
    if [[ "$force" != true ]]; then
        log err "[db purge] Purge is destructive. Re-run with --force to proceed."
        return 1
    fi

    # Hydrate DB vars from app env if not set
    local env_file=""
    env_file="$(_db_env_file)"
    if { [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_HOST:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_PASSWORD:-}" ]; } && [ -n "$env_file" ] && [ -f "$env_file" ]; then
        log debug "[db purge] Loading DB vars from app env: ${env_file}"
        if ! load_env_file_raw "${env_file}"; then
            log warn "[db purge] Failed to parse app env: ${env_file}"
        fi
    fi
    local db_config_present=false
    if [[ -n "${DB_HOST:-}" || -n "${DB_USERNAME:-}" || -n "${DB_DATABASE:-}" ]]; then
        db_config_present=true
    fi

    # Prompt if still missing essentials
    if [[ -z "${DB_USERNAME:-}" ]]; then
        DB_USERNAME=$(prompt_var "MYSQL_USER" "root" "MySQL/MariaDB user for purge:" false 60) || return 1
    fi
    if [[ -z "${DB_DATABASE:-}" ]]; then
        DB_DATABASE=$(prompt_var "MYSQL_DB" "" "MySQL/MariaDB database to purge:" false 60) || return 1
    fi
    if [[ -z "${DB_HOST:-}" ]]; then
        DB_HOST=$(prompt_var "MYSQL_HOST" "localhost" "MySQL/MariaDB host:" false 60) || return 1
    fi
    if [[ -z "${DB_PASSWORD:-}" && "${INM_FORCE_READ_DB_PW^^}" == "Y" ]]; then
        DB_PASSWORD=$(prompt_var "MYSQL_PASS" "" "Password for ${DB_USERNAME}:" true 60) || return 1
    fi

    local db_client=""
    db_client="$(select_db_client true "$db_config_present")"
    if [ -z "$db_client" ]; then
        log err "[db purge] No MySQL/MariaDB client found. Please install mysql or mariadb client tools."
        return 1
    fi

    local db_cmd=("$db_client" "-u${DB_USERNAME}" "-h${DB_HOST}" "-P${DB_PORT:-3306}")
    [[ -n "${DB_PASSWORD:-}" ]] && db_cmd+=("-p${DB_PASSWORD}")

    if ! "${db_cmd[@]}" -e "SELECT 1" >/dev/null 2>&1; then
        log warn "[db purge] Initial DB credentials failed; prompting for elevated DB user."
        local elev_user elev_pw
        elev_user=$(prompt_var "MYSQL_USER" "${DB_USERNAME:-root}" "MySQL/MariaDB user for purge (e.g., root):" false 60) || return 1
        elev_pw=$(prompt_var "MYSQL_PASS" "" "Password for ${elev_user} (leave blank if none):" true 60) || return 1
        db_cmd=("$db_client" "-u${elev_user}" "-h${DB_HOST}" "-P${DB_PORT:-3306}")
        [[ -n "$elev_pw" ]] && db_cmd+=("-p${elev_pw}")
        DB_USERNAME="$elev_user"
        DB_PASSWORD="$elev_pw"
        if ! "${db_cmd[@]}" -e "SELECT 1" >/dev/null 2>&1; then
            if [[ "${DB_HOST}" == "localhost" || "${DB_HOST}" == "127.0.0.1" ]]; then
                db_cmd=("$db_client" "-u${elev_user}" "-S" "${DB_SOCKET:-/var/run/mysqld/mysqld.sock}")
                [[ -n "$elev_pw" ]] && db_cmd+=("-p${elev_pw}")
                if ! "${db_cmd[@]}" -e "SELECT 1" >/dev/null 2>&1; then
                    log err "[db purge] Could not connect with provided elevated credentials (host or socket)."
                    return 1
                fi
            else
                log err "[db purge] Could not connect with provided elevated credentials."
                return 1
            fi
        fi
    fi

    local rows=()
    local query_output=""
    if ! query_output=$("${db_cmd[@]}" -N -B -e "SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.tables WHERE table_schema='${DB_DATABASE}'" 2>/dev/null); then
        log err "[db purge] Could not list tables for ${DB_DATABASE}."
        return 1
    fi
    while IFS= read -r row; do
        [[ -n "$row" ]] && rows+=("$row")
    done <<< "$query_output"

    if [ "${#rows[@]}" -eq 0 ]; then
        log ok "[db purge] No tables found in ${DB_DATABASE}."
        return 0
    fi

    local tables=()
    local views=()
    local row
    for row in "${rows[@]}"; do
        local name type
        name="${row%%$'\t'*}"
        type="${row#*$'\t'}"
        if [[ "$type" == "VIEW" ]]; then
            views+=("$name")
        else
            tables+=("$name")
        fi
    done

    log warn "[db purge] Removing ${#tables[@]} tables and ${#views[@]} views from '${DB_DATABASE}'."

    local batch_size=50
    local i
    if [ "${#views[@]}" -gt 0 ]; then
        for ((i=0; i<${#views[@]}; i+=batch_size)); do
            local chunk=("${views[@]:i:batch_size}")
            local drop_list=""
            local v
            for v in "${chunk[@]}"; do
                v="${v//\`/``}"
                drop_list="${drop_list:+$drop_list,}\`$v\`"
            done
            if ! "${db_cmd[@]}" "$DB_DATABASE" -e "DROP VIEW IF EXISTS ${drop_list};"; then
                log err "[db purge] Failed to drop views in ${DB_DATABASE}."
                return 1
            fi
        done
    fi

    if [ "${#tables[@]}" -gt 0 ]; then
        for ((i=0; i<${#tables[@]}; i+=batch_size)); do
            local chunk=("${tables[@]:i:batch_size}")
            local drop_list=""
            local t
            for t in "${chunk[@]}"; do
                t="${t//\`/``}"
                drop_list="${drop_list:+$drop_list,}\`$t\`"
            done
            if ! "${db_cmd[@]}" "$DB_DATABASE" -e "SET FOREIGN_KEY_CHECKS=0; DROP TABLE IF EXISTS ${drop_list}; SET FOREIGN_KEY_CHECKS=1;"; then
                log err "[db purge] Failed to drop tables in ${DB_DATABASE}."
                return 1
            fi
        done
    fi

    log ok "[db purge] Database '${DB_DATABASE}' is now empty."
}

# ---------------------------------------------------------------------
# db_table_count()
# Returns the number of tables in the current DB. Prints count on success.
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# db_table_count()
# Count tables in the configured database.
# Consumes: env: DB_* and INM_*; deps: select_db_client.
# Computes: table count.
# Returns: prints count; non-zero on failure.
# ---------------------------------------------------------------------
db_table_count() {
    if trace_suspend_if_sensitive_key "DB_PASSWORD"; then
        trap 'trace_resume' RETURN
    fi
    # Hydrate DB vars from app env if not set
    local env_file=""
    env_file="$(_db_env_file)"
    if { [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_HOST:-}" ] || [ -z "${DB_DATABASE:-}" ]; } && [ -n "$env_file" ] && [ -f "$env_file" ]; then
        log debug "[db_count] Loading DB vars from app env: $env_file"
        if ! load_env_file_raw "$env_file"; then
            log warn "[db_count] Failed to parse app env: $env_file"
        fi
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
# ---------------------------------------------------------------------
# dump_database()
# Dump the configured database to a SQL file.
# Consumes: args: out_file, extra_args; env: DB_* and INM_*; deps: select_db_dump.
# Computes: mysqldump output (sanitized).
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
dump_database() {
    local target_file="$1"
    [[ -z "$target_file" ]] && { log err "[dump_db] No target file provided."; return 1; }
    if trace_suspend_if_sensitive_key "DB_PASSWORD"; then
        trap 'trace_resume' RETURN
    fi

    # Hydrate DB vars from app env if not set
    local env_file=""
    env_file="$(_db_env_file)"
    if { [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_HOST:-}" ] || [ -z "${DB_DATABASE:-}" ]; } && [ -n "$env_file" ] && [ -f "$env_file" ]; then
        log debug "[dump_db] Loading DB vars from app env: $env_file"
        if ! load_env_file_raw "$env_file"; then
            log warn "[dump_db] Failed to parse app env: $env_file"
        fi
    fi

    if [[ "${INM_QUIET_DUMP:-false}" != true ]]; then
        log info "[dump_db] Dumping database to $target_file ..."
    fi

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
        if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
            if ! "${dump_cmd[@]}" > "$target_file"; then
                log err "[dump_db] Database dump failed using .env password"
                return 1
            fi
        else
            local dump_err
            dump_err="$(mktemp /tmp/.inm_dump_err_XXXXXX)" || dump_err=""
            if ! "${dump_cmd[@]}" > "$target_file" 2>"$dump_err"; then
                local err_line=""
                err_line="$(head -n1 "$dump_err" 2>/dev/null || true)"
                rm -f "$dump_err"
                log err "[dump_db] Database dump failed using .env password${err_line:+: $err_line}"
                return 1
            fi
            rm -f "$dump_err"
        fi
    else
        log debug "[dump_db] INM_FORCE_READ_DB_PW≠Y → Attempt .my.cnf"
        local dump_err=""
        dump_err="$(mktemp /tmp/.inm_dump_err_XXXXXX 2>/dev/null || printf "/tmp/.inm_dump_err_%s" "$$")"
        if ! "${dump_cmd[@]}" > "$target_file" 2>"$dump_err"; then
            if grep -qi "Access denied" "$dump_err"; then
                log warn "[dump_db] .my.cnf failed – prompting for password"
                local success=false
                local dump_cmd_base=("${dump_cmd[@]}")
                for attempt in {1..3}; do
                    DB_PASSWORD=$(prompt_var DB_PASSWORD "" \
                        "Enter database password (user: ${DB_USERNAME:-<unset>})" true 60) || {
                        log err "[dump_db] No password entered – aborting"
                        break
                    }
                    dump_cmd=("${dump_cmd_base[@]}" "-p$DB_PASSWORD")
                    if "${dump_cmd[@]}" > "$target_file" 2>"$dump_err"; then
                        success=true
                        break
                    else
                        log warn "[dump_db] Dump failed (attempt $attempt)"
                    fi
                done
                rm -f "$dump_err"
                [[ "$success" != true ]] && return 1
            else
                local err_out=""
                err_out="$(cat "$dump_err" 2>/dev/null || true)"
                log err "[dump_db] Dump failed for ${DB_DATABASE}@${DB_HOST} (${db_dump} exit ${err_out})"
                log err "[dump_db] Dump failed for ${DB_DATABASE}@${DB_HOST}. ${db_dump} output:"
                cat "$dump_err" >&2
                rm -f "$dump_err"
                return 1
            fi
        else
            rm -f "$dump_err"
        fi
    fi

    # Sanitize dump for portability: strip hardcoded DEFINERs
    if command -v sed >/dev/null 2>&1; then
        local tmp_sanitize target_dir
        target_dir="$(dirname "$target_file")"
        tmp_sanitize=$(mktemp "${target_dir%/}/.inm_dump_sanitize.XXXXXX" 2>/dev/null) || true
        if [[ -n "$tmp_sanitize" ]]; then
            # shellcheck disable=SC2016
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
# ---------------------------------------------------------------------
# create_database()
# Create database and user using elevated credentials.
# Consumes: env: DB_* and INM_*; deps: select_db_client.
# Computes: database/user creation.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
create_database() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping DB create."
        return 0
    fi
    if trace_suspend_if_sensitive_key "DB_PASSWORD"; then
        trap 'trace_resume' RETURN
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
    local elevated_auth_socket=false
    if [[ -n "$elevated_pass" && "${elevated_pass,,}" == "auth_socket" ]]; then
        elevated_auth_socket=true
    fi
    local current_user=""
    current_user="$(id -un 2>/dev/null || true)"

    log debug "[db] Running DB provisioning commands..."
    local -a db_cmd=()
    if [ "$elevated_auth_socket" = true ]; then
        if [[ "$db_host" != "localhost" && "$db_host" != "127.0.0.1" && "$db_host" != "::1" && "$db_host" != /* ]]; then
            log err "[db] auth_socket requires a local DB host (localhost or socket path)."
            exit 1
        fi
        local socket_path=""
        if [[ "$db_host" == /* ]]; then
            socket_path="$db_host"
        else
            socket_path="${DB_SOCKET:-/var/run/mysqld/mysqld.sock}"
        fi
        if [[ "$current_user" != "$elevated_user" ]]; then
            if [ "$EUID" -eq 0 ] && [ "$elevated_user" = "root" ]; then
                db_cmd=("$db_client")
            elif command -v sudo >/dev/null 2>&1; then
                if sudo -n -u "$elevated_user" true 2>/dev/null; then
                    db_cmd=(sudo -n -u "$elevated_user" "$db_client")
                else
                    log err "[db] auth_socket requires passwordless sudo for '${current_user}' or run as root (e.g., sudo inm core install --provision --force --override-enforced-user)."
                    exit 1
                fi
            else
                log err "[db] auth_socket requires sudo or running as $elevated_user."
                exit 1
            fi
        else
            db_cmd=("$db_client")
        fi
        db_cmd+=("-u${elevated_user}" "-S" "$socket_path")
    else
        db_cmd=("$db_client" "-h" "$db_host" "-P" "$db_port" "-u" "$elevated_user" "-p${elevated_pass}")
    fi

    if "${db_cmd[@]}" <<EOF
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
