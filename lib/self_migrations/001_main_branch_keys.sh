#!/usr/bin/env bash

# Migration 001: main-branch key rename to canonical schema.

declare -A MIG_001_KEY_MAP=(
    ["INM_BASE_DIRECTORY"]="INM_PATH_BASE_DIR"
    ["INM_INSTALLATION_DIRECTORY"]="INM_PATH_APP_DIR"
    ["INM_ENV_FILE"]="INM_PATH_APP_ENV_FILE"
    ["INM_TEMP_DOWNLOAD_DIRECTORY"]="INM_PATH_TMP_DOWNLOAD_DIR"
    ["INM_DUMP_OPTIONS"]="INM_DB_DUMP_OPTIONS"
    ["INM_BACKUP_DIRECTORY"]="INM_BACKUP_DIR"
    ["INM_FORCE_READ_DB_PW"]="INM_DB_FORCE_READ_PW_ENABLE"
    ["INM_ENFORCED_USER"]="INM_EXEC_USER"
    ["INM_ENFORCED_SHELL"]="INM_EXEC_SHELL_BIN"
    ["INM_PHP_EXECUTABLE"]="INM_RUNTIME_PHP_BIN"
    ["INM_ARTISAN_STRING"]="INM_RUNTIME_ARTISAN_CMD"
    ["INM_PROGRAM_NAME"]="INM_SELF_PROGRAM_NAME"
    ["INM_COMPATIBILITY_VERSION"]="INM_SELF_COMPAT_VERSION"
    ["INM_KEEP_BACKUPS"]="INM_BACKUP_RETENTION"
)

migration_001_replace_placeholders() {
    local value="$1"
    local legacy canon
    for legacy in "${!MIG_001_KEY_MAP[@]}"; do
        canon="${MIG_001_KEY_MAP[$legacy]}"
        value="${value//\${$legacy}/\${$canon}}"
        value="${value//\$$legacy/\$$canon}"
    done
    printf "%s" "$value"
}

migration_001_main_branch_keys() {
    local config_file="$1"
    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        return 0
    fi

    local migrated=false
    local legacy canon
    for legacy in "${!MIG_001_KEY_MAP[@]}"; do
        canon="${MIG_001_KEY_MAP[$legacy]}"
        if ! grep -q -E "^[[:space:]]*(export[[:space:]]+)?${legacy}[[:space:]]*=" "$config_file"; then
            continue
        fi
        if ! grep -q -E "^[[:space:]]*(export[[:space:]]+)?${canon}[[:space:]]*=" "$config_file"; then
            local raw=""
            raw="$(read_env_value_safe "$config_file" "$legacy" 2>/dev/null)"
            raw="$(migration_001_replace_placeholders "$raw")"
            if env_set cli "${canon}=${raw}" >/dev/null 2>&1; then
                migrated=true
            else
                log warn "[MIG] Could not persist ${canon}; check CLI config permissions."
                printf -v "$canon" '%s' "$raw"
                export "$canon"
            fi
        fi
        if env_unset cli "$legacy" >/dev/null 2>&1; then
            migrated=true
        fi
    done

    if [[ "$migrated" == true ]]; then
        load_env_file_raw "$config_file" || true
    fi
    return 0
}
