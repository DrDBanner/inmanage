#!/usr/bin/env bash

# ---------------------------------------------------------------------
# Core module: checks.sh
# Scope: environment/CLI dependency checks + config sanity helpers.
# Avoid: app/db/web operations; those live in services/helpers.
# Provides: core checks used by multiple commands.
# ---------------------------------------------------------------------

# Prevent double sourcing
[[ -n ${__CORE_CHECKS_LOADED:-} ]] && return
__CORE_CHECKS_LOADED=1

# shellcheck disable=SC1090,SC1091
if [[ -f "${LIB_DIR}/helpers/env_parse.sh" ]]; then
    source "${LIB_DIR}/helpers/env_parse.sh"
else
    log err "[ENV] Missing env parse helper: ${LIB_DIR}/helpers/env_parse.sh"
    return 1
fi

# ---------------------------------------------------------------------
# Environment and dependency checks
# Groups self-check helpers (env loading, required binaries, GH creds).
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# check_missing_settings()
# Ensures all default_settings keys are present in config, adding defaults.
# ---------------------------------------------------------------------
check_missing_settings() {
    # default_settings must be present; otherwise bootstrap/config is broken.
    # shellcheck disable=SC2154 # default_settings is defined in core/config.sh
    if ! declare -p default_settings >/dev/null 2>&1; then
        log err "[CMS] default_settings not available; ensure core/config.sh is loaded."
        exit 1
    fi

    updated=0
    for key in "${!default_settings[@]}"; do
        if ! grep -q "^$key=" "$INM_SELF_ENV_FILE"; then
            if [ ! -w "$INM_SELF_ENV_FILE" ]; then
                local current_user=""
                current_user="$(id -un 2>/dev/null || true)"
                log err "[CMS] Config not writable: $INM_SELF_ENV_FILE"
                if [ -n "${INM_ENFORCED_USER:-}" ] && [ "$current_user" != "$INM_ENFORCED_USER" ]; then
                    log_hint "CMS" "Fix: sudo -u ${INM_ENFORCED_USER} bash ./inmanage.sh"
                else
                    log_hint "CMS" "Fix: sudo chown ${current_user:-<your-user>} \"$INM_SELF_ENV_FILE\""
                fi
                return 1
            fi
            log warn "[CMS] $key not found in $INM_SELF_ENV_FILE. Adding with default value '${default_settings[$key]}'."
            local val="${default_settings[$key]}"
            local inline_comment=""
            if declare -p default_inline_comments >/dev/null 2>&1; then
                if [ -n "${default_inline_comments[$key]+_}" ] && [ -n "${default_inline_comments[$key]}" ]; then
                    inline_comment=" # ${default_inline_comments[$key]}"
                fi
            fi
            if _env_key_is_sensitive "$key"; then
                inline_comment=""
            fi
            printf '%s="%s"%s\n' "$key" "$val" "$inline_comment" >> "$INM_SELF_ENV_FILE"
            updated=1
        fi
    done
    if [ "$updated" -eq 1 ]; then
        log ok "[CMS] Updated $INM_SELF_ENV_FILE with missing settings. Reloading."
        load_env_file_raw "$INM_SELF_ENV_FILE"
    else
        log debug "[CMS] Loaded settings from $INM_SELF_ENV_FILE."
    fi

    if ! grep -q "^INM_INSTANCE_ID=" "$INM_SELF_ENV_FILE"; then
        local inst_id=""
        if declare -F env_resolve_instance_id >/dev/null 2>&1; then
            inst_id="$(env_resolve_instance_id "${INM_BASE_DIRECTORY:-}" "${INM_ENV_FILE:-}")"
        fi
        if [[ -n "$inst_id" ]] && ! grep -q "^INM_INSTANCE_ID=" "$INM_SELF_ENV_FILE"; then
            printf 'INM_INSTANCE_ID="%s"\n' "$inst_id" >> "$INM_SELF_ENV_FILE"
            load_env_file_raw "$INM_SELF_ENV_FILE"
        fi
    fi
}

# ---------------------------------------------------------------------
# check_commands()
# Verifies required external tools and shell builtins are available.
# ---------------------------------------------------------------------
# check_commands_list()
# List required external tools for a given mode.
# Consumes: args: mode.
# Computes: command list.
# Returns: list on stdout (one per line).
# ---------------------------------------------------------------------
check_commands_list() {
    local mode="${1:-full}"
    local commands=()
    case "$mode" in
        preflight)
            commands=(php git curl tar rsync zip unzip composer jq awk sed find xargs touch tee sha256sum)
            ;;
        self)
            commands=(curl wc tar cp mv mkdir chown find rm grep xargs touch sed tee rsync awk git zip unzip)
            ;;
        self_update)
            commands=(git)
            ;;
        *)
            commands=(curl wc tar cp mv mkdir chown find rm grep xargs php touch sed sudo tee rsync awk jq git composer zip unzip)
            ;;
    esac
    printf "%s\n" "${commands[@]}"
}

# ---------------------------------------------------------------------
# check_commands_missing()
# Return missing commands for a given mode.
# Consumes: args: mode; deps: check_commands_list, select_db_client, select_db_dump.
# Computes: missing command list.
# Returns: list on stdout (one per line).
# ---------------------------------------------------------------------
check_commands_missing() {
    local mode="${1:-full}"
    local include_db=true
    case "$mode" in
        preflight|self|self_update) include_db=false ;;
    esac

    local missing_commands=()
    local -a commands=()
    mapfile -t commands < <(check_commands_list "$mode")

    local cmd=""
    for cmd in "${commands[@]}"; do
        if [[ "$cmd" == "sha256sum" ]]; then
            if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1 && ! command -v sha256 >/dev/null 2>&1; then
                missing_commands+=("sha256sum/shasum/sha256")
            fi
            continue
        fi
        if ! command -v "$cmd" &>/dev/null; then
            if [[ "$cmd" == "sudo" ]] && command -v doas >/dev/null 2>&1; then
                continue
            fi
            missing_commands+=("$cmd")
        fi
    done

    if [[ "$include_db" == true ]]; then
        local db_client=""
        local db_dump=""
        db_client="$(select_db_client false false)"
        db_dump="$(select_db_dump "$db_client")"
        if [ -z "$db_client" ]; then
            missing_commands+=("mysql/mariadb")
        fi
        if [ -z "$db_dump" ]; then
            missing_commands+=("mysqldump/mariadb-dump")
        fi
    fi

    if [ ${#missing_commands[@]} -gt 0 ]; then
        printf "%s\n" "${missing_commands[@]}"
    fi
}

# ---------------------------------------------------------------------
# check_db_tools_preflight()
# Emit database client/dump status for preflight.
# Consumes: args: add_fn, tag; env: INM_ENV_FILE/INM_INSTALLATION_PATH/DB_*; deps: expand_path_vars, select_db_client, select_db_dump.
# Computes: DB tooling status lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
check_db_tools_preflight() {
    local add_fn="$1"
    local tag="${2:-CMD}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    db_emit() {
        local status="$1"
        local detail="$2"
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

    local db_cmds_required=false
    local db_config_present=false
    if [[ -n "${DB_HOST:-}" || -n "${DB_USERNAME:-}" || -n "${DB_DATABASE:-}" ]]; then
        db_cmds_required=true
        db_config_present=true
    else
        local env_for_db=""
        if [ -n "${INM_ENV_FILE:-}" ]; then
            env_for_db="$(expand_path_vars "$INM_ENV_FILE")"
        elif [ -n "${INM_INSTALLATION_PATH:-}" ]; then
            env_for_db="${INM_INSTALLATION_PATH%/}/.env"
        fi
        if [ -n "$env_for_db" ] && [ -f "$env_for_db" ]; then
            if grep -qE '^DB_(HOST|USERNAME|DATABASE)=' "$env_for_db" 2>/dev/null; then
                db_cmds_required=true
                db_config_present=true
            fi
        fi
    fi
    local db_scope_note=""
    local db_missing_status="ERR"
    if [ "$db_cmds_required" != true ]; then
        db_scope_note=" (DB not configured)"
        db_missing_status="WARN"
    fi

    local have_mysql=false
    local have_mariadb=false
    local have_mysqldump=false
    local have_mariadb_dump=false
    command -v mysql >/dev/null 2>&1 && have_mysql=true
    command -v mariadb >/dev/null 2>&1 && have_mariadb=true
    command -v mysqldump >/dev/null 2>&1 && have_mysqldump=true
    command -v mariadb-dump >/dev/null 2>&1 && have_mariadb_dump=true

    local db_client=""
    local db_dump=""
    local db_client_note=""
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
                    db_client_note=" (INM_DB_CLIENT)"
                    ;;
                *)
                    db_emit WARN "INM_DB_CLIENT ignored (use mysql or mariadb)"
                    ;;
            esac
        else
            if [ "$db_config_present" != true ]; then
                db_client_note=" (both installed; DB not configured)"
            else
                db_client_note=" (both installed)"
            fi
        fi
    fi

    if [ "$db_client" = "mariadb" ] && [ "$have_mariadb_dump" = true ]; then
        db_dump="mariadb-dump"
    elif [ "$db_client" = "mysql" ] && [ "$have_mysqldump" = true ]; then
        db_dump="mysqldump"
    elif [ "$have_mysqldump" = true ]; then
        db_dump="mysqldump"
    elif [ "$have_mariadb_dump" = true ]; then
        db_dump="mariadb-dump"
    fi

    if [ "$have_mysql" = true ] || [ "$have_mariadb" = true ]; then
        if [ "$have_mysql" = true ] && [ "$have_mariadb" = true ]; then
            db_emit OK "DB client: ${db_client:-mysql}${db_client_note} (mysql + mariadb available)"
        else
            db_emit OK "DB client: ${db_client:-mysql}${db_client_note}"
        fi
    else
        db_emit "$db_missing_status" "DB client missing (need mysql or mariadb)${db_scope_note}"
    fi

    if [ "$have_mysqldump" = true ] || [ "$have_mariadb_dump" = true ]; then
        if [ "$have_mysqldump" = true ] && [ "$have_mariadb_dump" = true ]; then
            db_emit OK "DB dump: ${db_dump:-mysqldump} (mysqldump + mariadb-dump available)"
        else
            db_emit OK "DB dump: ${db_dump:-mysqldump}"
        fi
    else
        db_emit "$db_missing_status" "DB dump tool missing (need mysqldump or mariadb-dump)${db_scope_note}"
    fi
}

# ---------------------------------------------------------------------
# check_commands()
# Verifies required external tools and shell builtins are available.
# ---------------------------------------------------------------------
check_commands() {
    local mode="${1:-full}"
    local missing_commands=()
    mapfile -t missing_commands < <(check_commands_missing "$mode")

    local shell_builtins=("read")
    for builtin in "${shell_builtins[@]}"; do
        if ! type "$builtin" &>/dev/null; then
            log warn "[CC] Warning: Shell builtin '$builtin' not found – is this running in Bash?"
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log err "[CC] Dependency Checks: The following commands are not available:"
        for missing in "${missing_commands[@]}"; do
            log err "[CC]  - $missing"
        done
        log note "[CC] Please install the missing commands to proceed. Hints for different distributions: https://invoiceninja.github.io/en/self-host-installation/#linux-server-configs"
        exit 1
    else
        log debug "[CC] All required external commands are available."
    fi
}

# ---------------------------------------------------------------------
# check_envs()
# Orchestrates base dir check, config presence/creation, user switch,
# and provision handling.
# ---------------------------------------------------------------------
check_envs() {
    log debug "[ENV] Check starts."

    if [[ "${CMD_CONTEXT:-}" == "self" || "${LEGACY_CMD:-}" == "version" ]]; then
        log debug "[ENV] Skipping project config checks for self/version."
        return 0
    fi
    local allow_missing_config=false
    local skip_config_load=false
    if [[ "${CMD_CONTEXT:-}" == "core" && ( "${CMD_ACTION:-}" == "health" || "${CMD_ACTION:-}" == "info" ) ]]; then
        allow_missing_config=true
    fi
    if [[ "${CMD_CONTEXT:-}" == "core" && "${CMD_ACTION:-}" == "get" ]]; then
        allow_missing_config=true
    fi
    if [[ "${LEGACY_CMD:-}" == "health" || "${LEGACY_CMD:-}" == "info" ]]; then
        allow_missing_config=true
    fi

    if [[ "$allow_missing_config" != true && -n "${INM_BASE_DIRECTORY:-}" ]]; then
        check_base_directory_valid_and_enter || {
            log err "[ENV] Base directory check failed. Aborting."
            exit 1
        }
    fi

    resolve_env_paths

    log debug "[ENV] Current config target: ${INM_SELF_ENV_FILE:-<unset>}"
    if [ -n "${INM_SELF_ENV_FILE:-}" ]; then
        log debug "[ENV] Config exists? $( [ -f "$INM_SELF_ENV_FILE" ] && echo yes || echo no )"
        if [[ "$INM_SELF_ENV_FILE" == "true" || "$INM_SELF_ENV_FILE" == "false" ]]; then
            log debug "[ENV] Resetting bogus config value: $INM_SELF_ENV_FILE"
            unset INM_SELF_ENV_FILE
        fi
    fi

    # Clean up bogus --config entries set by flags without values
    if [[ "${NAMED_ARGS[config]:-}" == "true" || "${NAMED_ARGS[config]:-}" == "false" ]]; then
        unset 'NAMED_ARGS[config]'
    fi

    if [ -z "${INM_SELF_ENV_FILE:-}" ] || [ ! -f "$INM_SELF_ENV_FILE" ]; then
        # Fallback: if a local .inmanage/.env.inmanage exists in PWD or base dir, use it
        if [ -f ".inmanage/.env.inmanage" ]; then
            INM_SELF_ENV_FILE="$PWD/.inmanage/.env.inmanage"
            if should_suppress_pre_switch_logs; then
                log debug "[ENV] Using local .inmanage/.env.inmanage at $INM_SELF_ENV_FILE"
            else
                log info "[ENV] Using local .inmanage/.env.inmanage at $INM_SELF_ENV_FILE"
            fi
        elif [ -n "${INM_BASE_DIRECTORY:-}" ] && [ -f "${INM_BASE_DIRECTORY%/}/.inmanage/.env.inmanage" ]; then
            INM_SELF_ENV_FILE="${INM_BASE_DIRECTORY%/}/.inmanage/.env.inmanage"
            if should_suppress_pre_switch_logs; then
                log debug "[ENV] Using base .inmanage/.env.inmanage at $INM_SELF_ENV_FILE"
            else
                log info "[ENV] Using base .inmanage/.env.inmanage at $INM_SELF_ENV_FILE"
            fi
        fi
    fi

    local config_unreadable_hint=false
    if [ -z "${INM_SELF_ENV_FILE:-}" ] || [ ! -f "$INM_SELF_ENV_FILE" ]; then
        local perm_hint=""
        if [ -d ".inmanage" ] && [ ! -x ".inmanage" ]; then
            perm_hint="$PWD/.inmanage/.env.inmanage"
        elif [ -n "${INM_BASE_DIRECTORY:-}" ] && [ -d "${INM_BASE_DIRECTORY%/}/.inmanage" ] && [ ! -x "${INM_BASE_DIRECTORY%/}/.inmanage" ]; then
            perm_hint="${INM_BASE_DIRECTORY%/}/.inmanage/.env.inmanage"
        fi

        if [ -n "$perm_hint" ]; then
            INM_SELF_ENV_FILE="$perm_hint"
            config_unreadable_hint=true
        fi
    fi

    if [ -z "${INM_SELF_ENV_FILE:-}" ] || { [ ! -f "$INM_SELF_ENV_FILE" ] && [ "$config_unreadable_hint" != true ]; }; then
        log note "[ENV] Project config file not found."

        if [[ "$allow_missing_config" == true ]]; then
            log info "[ENV] Continuing without project config (health mode)."
            skip_config_load=true
        fi

        if [[ "$skip_config_load" != true ]]; then
            if [ "${NAMED_ARGS[auto_create_config]}" = true ]; then
                log note "[ENV] Creating project config because --auto_create_config=true was passed."
                create_own_config
            else
                local auto_create_answer
                auto_create_answer=$(prompt_var "AUTO_CREATE_CONFIG" "no" \
                    "No project config found. Do you want to create a new configuration now?" false 60) || {
                    log err "[ENV] Timeout or error while prompting for config creation."
                    exit 1
                }

                if [[ "$auto_create_answer" =~ ^([yY][eE][sS]|[jJ][aA]|[yY])$ ]]; then
                    create_own_config || {
                        log err "[ENV] Project configuration creation failed!"
                        exit 1
                    }
                else
                    log err "[ENV] Project configuration creation declined. Aborting."
                    exit 1
                fi
            fi
        fi
    fi

    if [[ "$skip_config_load" != true ]]; then
        persist_derived_config

        # Config was found or created – validate and load
        if [ ! -r "$INM_SELF_ENV_FILE" ]; then
            local current_user=""
            current_user="$(id -un 2>/dev/null || true)"
            log err "[ENV] Project config file '$INM_SELF_ENV_FILE' is not readable. Aborting."
            if [ -n "${INM_ENFORCED_USER:-}" ] && [ "$current_user" != "$INM_ENFORCED_USER" ]; then
                log_hint "ENV" "Run as enforced user: sudo -u ${INM_ENFORCED_USER} inm core health"
                log_hint "ENV" "Or run as root with: sudo inm core health --override-enforced-user"
            else
                log_hint "ENV" "CLI config defaults to 600 for security. Fix options: run as enforced user, add your user to the app group, or relax CLI config mode."
                log_hint "ENV" "Directory access also matters: .inmanage needs +x for your user (group membership or chmod/chgrp)."
                log_hint "ENV" "Set mode (group): sudo inm env set cli INM_CLI_ENV_MODE=640"
                log_hint "ENV" "Set mode (world, if no secrets): sudo inm env set cli INM_CLI_ENV_MODE=644"
                log_hint "ENV" "Apply permissions: sudo inm core health --fix-permissions"
            fi
            exit 1
        fi

        log debug "[ENV] Loading project configuration from: $INM_SELF_ENV_FILE"
        load_env_file_raw "$INM_SELF_ENV_FILE" || {
            log err "[ENV] Failed to load project configuration."
            exit 1
        }
        if should_suppress_pre_switch_logs; then
            log debug "[ENV] Inmanage CLI config loaded: ${INM_SELF_ENV_FILE}"
        else
            log info "[ENV] Inmanage CLI config loaded: ${INM_SELF_ENV_FILE}"
        fi

        check_base_directory_valid_and_enter || {
            log err "[ENV] Base directory check failed. Aborting."
            exit 1
        }
    fi

    INM_ENV_FILE="$(path_expand_no_eval "${INM_ENV_FILE:-}")"
    INM_ARTISAN_STRING="$(path_expand_no_eval "${INM_ARTISAN_STRING:-}")"
    INM_PROVISION_ENV_FILE="$(path_expand_no_eval "${INM_PROVISION_ENV_FILE:-}")"
    INM_SELF_ENV_FILE="$(path_expand_no_eval "${INM_SELF_ENV_FILE:-}")"
    INM_CACHE_GLOBAL_DIRECTORY="$(path_expand_no_eval "${INM_CACHE_GLOBAL_DIRECTORY:-}")"
    INM_CACHE_LOCAL_DIRECTORY="$(path_expand_no_eval "${INM_CACHE_LOCAL_DIRECTORY:-}")"
    INM_BACKUP_DIRECTORY="$(path_expand_no_eval "${INM_BACKUP_DIRECTORY:-}")"
    INM_HISTORY_LOG_FILE="$(path_expand_no_eval "${INM_HISTORY_LOG_FILE:-}")"

    # Normalize base dir to always carry a trailing slash for consistent concatenation.
    if [ -n "${INM_BASE_DIRECTORY:-}" ]; then
        INM_BASE_DIRECTORY="$(ensure_trailing_slash "$INM_BASE_DIRECTORY")"
        log debug "[ENV] Normalized base directory: $INM_BASE_DIRECTORY"
    fi

    # Normalize installation path in case INM_INSTALLATION_DIRECTORY is absolute.
    INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
    if [[ -n "${INM_INSTALLATION_PATH:-}" ]]; then
        local env_state=""
        if [[ -n "${INM_ENV_FILE:-}" ]]; then
            env_state="$(file_read_state "$INM_ENV_FILE")"
        fi
        if [[ "$env_state" == "exists_unreadable" || "$env_state" == "permission" ]]; then
            if [[ "${INM_ENV_WARNED:-false}" == true ]]; then
                log debug "[ENV] App .env not readable: $INM_ENV_FILE (permission issue)."
            elif should_suppress_pre_switch_logs; then
                log debug "[ENV] App .env not readable: $INM_ENV_FILE (permission issue)."
                INM_ENV_WARNED=true
            else
                log warn "[ENV] App .env not readable: $INM_ENV_FILE (permission issue)."
                INM_ENV_WARNED=true
            fi
        fi
        # If the resolved .env path is missing, rebuild it relative to the normalized install path.
        if [ -z "${INM_ENV_FILE:-}" ] || { [ ! -f "$INM_ENV_FILE" ] && [[ "$env_state" != "exists_unreadable" && "$env_state" != "permission" ]]; }; then
            INM_ENV_FILE="${INM_INSTALLATION_PATH%/}/.env"
            log debug "[ENV] Derived INM_ENV_FILE via installation path: $INM_ENV_FILE"
        fi
        # If base directory is unset, anchor it to the install parent to keep rollbacks/backups aligned.
        if [ -z "${INM_BASE_DIRECTORY:-}" ]; then
            INM_BASE_DIRECTORY="$(dirname "${INM_INSTALLATION_PATH%/}")/"
            log warn "[ENV] INM_BASE_DIRECTORY was empty; using install parent: $INM_BASE_DIRECTORY"
        fi
    fi

    maybe_migrate_legacy_cli "$@" || exit 1

    enforce_user_switch --user="$INM_ENFORCED_USER" "$@"

    log debug "[ENV] Current working directory: $PWD"
    log debug "[ENV] Script Name: $SCRIPT_NAME"
    log debug "[ENV] Script Path: $SCRIPT_PATH"
    log debug "[ENV] Current user: $(whoami)"
    log debug "[ENV] Current shell: $SHELL"
    log debug "[ENV] Base directory: $INM_BASE_DIRECTORY"
    log debug "[ENV] Script location: $(realpath "$0")"
    log debug "[ENV] Current configuration file: $INM_SELF_ENV_FILE"
    log debug "[ENV] Enforced user: ${INM_ENFORCED_USER:-<not set>}"

    if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "$INM_SELF_ENV_FILE" ]; then
        check_missing_settings
        check_provision_file
    fi
}

# ---------------------------------------------------------------------
# check_base_directory_valid_and_enter()
# ---------------------------------------------------------------------
check_base_directory_valid_and_enter() {
    log debug "[DIR] Checking base directory: $INM_BASE_DIRECTORY"
    if [ -z "$INM_BASE_DIRECTORY" ]; then
        log debug "[DIR] Detecting base directory via .env/auto-discovery."
        return 0
    fi

    if [ ! -d "$INM_BASE_DIRECTORY" ]; then
        log err "[DIR] The path '$INM_BASE_DIRECTORY' does not exist or is not a directory."
        log err "Please double-check your configuration or provide a valid --base-directory."
        return 1
    fi

    cd "$INM_BASE_DIRECTORY" || {
        log err "[DIR] Couldn't change into base directory: $INM_BASE_DIRECTORY"
        log err "Check permissions or correct the path via --base-directory"
        return 1
    }

    log debug "[DIR] Working directory changed to: $INM_BASE_DIRECTORY"
    return 0
}

# ---------------------------------------------------------------------
# check_provision_file()
# ---------------------------------------------------------------------
check_provision_file() {
    if [ ! -f "$INM_PROVISION_ENV_FILE" ]; then
        log debug "[PVF] No provision file found. Skipping provisioning."
        return 0
    fi

    # Only run provisioning when explicitly requested
    if [[ "${NAMED_ARGS[provision]:-false}" != true ]]; then
        log debug "[PVF] Provision file present but --provision not set; skipping."
        return 0
    fi

    if trace_suspend_if_sensitive_key "DB_PASSWORD"; then
        trap 'trace_resume' RETURN
    fi

    log ok "[PVF] Provision file found. Loading..."
    load_env_file_raw "$INM_PROVISION_ENV_FILE" || {
        log err "[PVF] Failed to load DB variables from $INM_PROVISION_ENV_FILE"
        exit 1
    }

    local missing_vars=()
    for var in DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done
    if [ "${#missing_vars[@]}" -gt 0 ]; then
        log err "[PVF] Missing required DB variables in provision file: ${missing_vars[*]}"
        exit 1
    fi

    log ok "Provision file loaded. Starting installation logic."
    local db_client=""
    db_client="$(select_db_client false true)"
    if [ -z "$db_client" ]; then
        log err "[PVF] No MySQL/MariaDB client available (need mysql or mariadb)."
        exit 1
    fi
    # shellcheck disable=SC2154
    if [ "$force_update" != true ]; then
        log info "[PVF] You have 10 seconds to cancel this operation if you do not want to run the provision."
        sleep 10
    fi

    local elevated_username="${DB_ELEVATED_USERNAME:-}"
    local elevated_password="${DB_ELEVATED_PASSWORD:-}"
    local elevated_auth_socket=false
    if [[ -n "$elevated_password" && "${elevated_password,,}" == "auth_socket" ]]; then
        elevated_auth_socket=true
    fi
    local current_user=""
    current_user="$(id -un 2>/dev/null || true)"
    if [ -n "$elevated_username" ]; then
        log info "[PVF] Elevated SQL user '$elevated_username' found."

        if [ "$elevated_auth_socket" = true ]; then
            if [[ "$DB_HOST" != "localhost" && "$DB_HOST" != "127.0.0.1" && "$DB_HOST" != "::1" && "$DB_HOST" != /* ]]; then
                log err "[PVF] auth_socket requires a local DB host (localhost or socket path)."
                exit 1
            fi
            local socket_path=""
            if [[ "$DB_HOST" == /* ]]; then
                socket_path="$DB_HOST"
            else
                socket_path="${DB_SOCKET:-/var/run/mysqld/mysqld.sock}"
            fi
            local -a elevated_cmd=()
            if [[ "$current_user" != "$elevated_username" ]]; then
                if [ "$EUID" -eq 0 ] && [ "$elevated_username" = "root" ]; then
                    elevated_cmd=("$db_client")
                elif command -v sudo >/dev/null 2>&1; then
                    if sudo -n -u "$elevated_username" true 2>/dev/null; then
                        elevated_cmd=(sudo -n -u "$elevated_username" "$db_client")
                    else
                        log err "[PVF] auth_socket requires passwordless sudo for '${current_user}' or run as root (e.g., sudo inm core install --provision --force --override-enforced-user)."
                        exit 1
                    fi
                else
                    log err "[PVF] auth_socket requires sudo or running as $elevated_username."
                    exit 1
                fi
            else
                elevated_cmd=("$db_client")
            fi
            elevated_cmd+=("-u${elevated_username}" "-S" "$socket_path")

            if "${elevated_cmd[@]}" -e 'quit' 2>/dev/null; then
                log ok "[PVF] Connection with elevated auth_socket credentials successful."

                if "${elevated_cmd[@]}" -e "USE \`$DB_DATABASE\`;" 2>/dev/null; then
                    log ok "[PVF] Database '$DB_DATABASE' already exists."
                else
                    log warn "[PVF] Database '$DB_DATABASE' does not exist. Creating..."
                    create_database "$elevated_username" "$elevated_password"
                fi
            else
                log err "[PVF] auth_socket connection failed; check sudo and local socket auth."
                exit 1
            fi
        else
            if "$db_client" -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e 'quit' 2>/dev/null; then
                log ok "[PVF] Connection with elevated credentials successful."

                if "$db_client" -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e "USE \`$DB_DATABASE\`;" 2>/dev/null; then
                    log ok "[PVF] Database '$DB_DATABASE' already exists."
                else
                    log warn "[PVF] Database '$DB_DATABASE' does not exist. Creating..."
                    create_database "$elevated_username" "$elevated_password"
                fi
            else
                log warn "[PVF] Connection with elevated user failed. Trying interactive password prompt..."

                if [ -z "$elevated_password" ]; then
                    elevated_password=$(prompt_var "DB_ELEVATED_PASSWORD" "" "Enter the password for elevated user '$elevated_username'" true)
                fi

                if "$db_client" -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e 'quit' 2>/dev/null; then
                    log ok "[PVF] Retry successful with prompted password."

                    if "$db_client" -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e "USE \`$DB_DATABASE\`;" 2>/dev/null; then
                        log ok "[PVF] Database '$DB_DATABASE' already exists."
                    else
                        log warn "[PVF] Database '$DB_DATABASE' does not exist. Creating..."
                        create_database "$elevated_username" "$elevated_password"
                    fi
                else
                    log err "[PVF] Retry with elevated credentials failed."
                    exit 1
                fi
            fi
        fi
    else
        log info "[PVF] No elevated credentials found. Trying with standard user '$DB_USERNAME'..."

        if "$db_client" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e 'quit' 2>/dev/null; then
            if "$db_client" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "USE \`$DB_DATABASE\`;" 2>/dev/null; then
                log ok "[PVF] Standard credentials valid. Database '$DB_DATABASE' exists."
            else
                log err "[PVF] Database '$DB_DATABASE' not found and cannot be created without elevated user."
                exit 1
            fi
        else
            log err "[PVF] Connection with standard user failed."
            exit 1
        fi
    fi
    run_installation "Provisioned"
}
