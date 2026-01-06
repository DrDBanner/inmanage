#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HELPER_DB_CLIENT_LOADED:-} ]] && return
__HELPER_DB_CLIENT_LOADED=1

# ---------------------------------------------------------------------
# select_db_client()
# Pick a MySQL-compatible client available on the system.
# Consumes: args: allow_prompt, db_config_present; env: INM_DB_CLIENT; deps: prompt_var.
# Computes: mysql/mariadb selection.
# Returns: prints client name or empty string.
# ---------------------------------------------------------------------
select_db_client() {
    local allow_prompt="${1:-false}"
    local db_config_present="${2:-false}"
    local have_mysql=false
    local have_mariadb=false

    command -v mysql >/dev/null 2>&1 && have_mysql=true
    command -v mariadb >/dev/null 2>&1 && have_mariadb=true

    local db_client=""
    if [ "$have_mysql" = true ] && [ "$have_mariadb" != true ]; then
        db_client="mysql"
    elif [ "$have_mariadb" = true ] && [ "$have_mysql" != true ]; then
        db_client="mariadb"
    elif [ "$have_mysql" = true ] && [ "$have_mariadb" = true ]; then
        db_client="mysql"
        if [ -n "${INM_DB_CLIENT:-}" ]; then
            case "${INM_DB_CLIENT,,}" in
                mysql|mariadb)
                    db_client="${INM_DB_CLIENT,,}"
                    ;;
            esac
        elif [ "$db_config_present" != true ] && [ "$allow_prompt" = true ] && [[ -t 0 ]]; then
            local choice=""
            choice=$(prompt_var "DB_CLIENT" "mysql" \
                "Both mysql and mariadb clients found but DB is not configured yet. Which DB system will be used? (mysql/mariadb)" \
                false 30) || true
            choice="${choice,,}"
            case "$choice" in
                mysql|mariadb)
                    db_client="$choice"
                    ;;
            esac
        fi
    fi

    echo "$db_client"
}

# ---------------------------------------------------------------------
# select_db_dump()
# Pick a MySQL-compatible dump tool.
# Consumes: args: db_client.
# Computes: dump binary selection.
# Returns: prints dump tool name or empty string.
# ---------------------------------------------------------------------
select_db_dump() {
    local db_client="${1:-}"
    local have_mysqldump=false
    local have_mariadb_dump=false

    command -v mysqldump >/dev/null 2>&1 && have_mysqldump=true
    command -v mariadb-dump >/dev/null 2>&1 && have_mariadb_dump=true

    local db_dump=""
    if [ "$db_client" = "mariadb" ] && [ "$have_mariadb_dump" = true ]; then
        db_dump="mariadb-dump"
    elif [ "$db_client" = "mysql" ] && [ "$have_mysqldump" = true ]; then
        db_dump="mysqldump"
    elif [ "$have_mysqldump" = true ]; then
        db_dump="mysqldump"
    elif [ "$have_mariadb_dump" = true ]; then
        db_dump="mariadb-dump"
    fi

    echo "$db_dump"
}
