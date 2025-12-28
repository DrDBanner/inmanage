#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__CORE_CHECKS_LOADED:-} ]] && return
__CORE_CHECKS_LOADED=1

# ---------------------------------------------------------------------
# Environment and dependency checks
# Groups self-check helpers (env loading, required binaries, GH creds).
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# load_env_file_raw()
# Parses and exports selected variables from an env file safely.
# ---------------------------------------------------------------------
load_env_file_raw() {
    local file="$1"
    log debug "[ENV] Loading relevant vars from: $file"

    local tmpfile
    tmpfile=$(mktemp /tmp/.inm_env_XXXXXX) || {
        log err "[ENV] Failed to create temp file"
        return 1
    }
    chmod 600 "$tmpfile"

    # Parse line by line to keep complex passwords/characters intact.
    # - Skip blank and full-line comments
    # - Respect quotes: if quoted, do NOT strip inline #
    # - Unquoted values: strip inline comment and trim, then quote for export
    while IFS= read -r line || [ -n "$line" ]; do
        # skip empty
        [[ -z "${line//[[:space:]]/}" ]] && continue
        # skip full-line comments
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" =~ ^# ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            local key val raw
            key="${BASH_REMATCH[1]}"
            raw="${BASH_REMATCH[2]}"
            # filter relevant prefixes only
            if [[ ! "$key" =~ ^(DB_|ELEVATED_|NINJA_|PDF_|INM_)[A-Z_]*$ ]]; then
                continue
            fi
            # trim leading spaces from val
            val="${raw#"${raw%%[![:space:]]*}"}"
            # quoted values: strip only outer quotes, keep inner content as-is
            if [[ "$val" =~ ^\"(.*)\"$ ]]; then
                val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            else
                # unquoted: drop inline comment, trim trailing spaces
                val="${val%%#*}"
                val="${val%"${val##*[![:space:]]}"}"
            fi
            printf 'export %s=%q\n' "$key" "$val" >> "$tmpfile"
        fi
    done < "$file"

    log debug "[ENV] Parsed data: $(tr "\n" " " < "$tmpfile")"

    # shellcheck disable=SC1091
    # shellcheck disable=SC1090
    if ! . "$tmpfile"; then
        log err "[ENV] Failed to source vars from $tmpfile"
        rm -f "$tmpfile"
        return 1
    fi

    rm -f "$tmpfile"
    log debug "[ENV] Successfully loaded vars from: $file"
}

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
            echo "$key=\"$val\"" >> "$INM_SELF_ENV_FILE"
            updated=1
        fi
    done
    if [ "$updated" -eq 1 ]; then
        log ok "[CMS] Updated $INM_SELF_ENV_FILE with missing settings. Reloading."
        load_env_file_raw "$INM_SELF_ENV_FILE"
    else
        log debug "[CMS] Loaded settings from $INM_SELF_ENV_FILE."
    fi
}

# ---------------------------------------------------------------------
# check_commands()
# Verifies required external tools and shell builtins are available.
# ---------------------------------------------------------------------
check_commands() {
    local commands=("curl" "wc" "tar" "cp" "mv" "mkdir" "chown" "find" "rm" "grep" "xargs" "php" "touch" "sed" "sudo" "tee" "rsync" "awk" "jq" "git" "composer" "zip" "unzip" "sha256sum")
    local missing_commands=()

    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done

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
# check_github_rate_limit()
# Warns if GitHub API rate limit is low to encourage token usage.
# ---------------------------------------------------------------------
check_github_rate_limit() {
    local auth_flag=()
    case "${INM_GH_API_CREDENTIALS:-}" in
        token:*)
            auth_flag=(-H "Authorization: token ${INM_GH_API_CREDENTIALS#token:}")
            ;;
        *:*)
            auth_flag=(-u "${INM_GH_API_CREDENTIALS//:/ }")
            ;;
    esac
    local rl
    rl=$(curl -s --fail "${auth_flag[@]}" https://api.github.com/rate_limit 2>/dev/null) || return
    if ! command -v jq >/dev/null 2>&1; then
        return
    fi
    local remaining limit reset
    remaining=$(echo "$rl" | jq -r '.rate.remaining // empty')
    limit=$(echo "$rl" | jq -r '.rate.limit // empty')
    reset=$(echo "$rl" | jq -r '.rate.reset // empty')
    if [[ -n "$remaining" && -n "$limit" ]]; then
        if (( remaining <= 5 )); then
            local reset_human=""
            if [[ -n "$reset" ]] && command -v date >/dev/null 2>&1; then
                reset_human=$(date -d @"$reset" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
            fi
            log warn "[DN] GitHub API rate low: ${remaining}/${limit} remaining${reset_human:+ (reset: $reset_human)}. Set INM_GH_API_CREDENTIALS=token:<PAT> to increase limits."
        else
            log debug "[DN] GitHub API rate: ${remaining}/${limit} remaining."
        fi
    fi
}

# ---------------------------------------------------------------------
# check_envs()
# Orchestrates base dir check, config presence/creation, user switch,
# and provision handling.
# ---------------------------------------------------------------------
check_envs() {
    log debug "[ENV] Check starts."

    check_base_directory_valid_and_enter || {
        log err "[ENV] Base directory check failed. Aborting."
        exit 1
    }

    resolve_env_paths

    # If base directory was empty initially but got derived from .env,
    # try to enter it now. This keeps backward compat with explicit --base-directory
    # while allowing auto-derivation. Remove this block if we make base mandatory again.
    if [ -n "$INM_BASE_DIRECTORY" ] && [ "$PWD/" != "${INM_BASE_DIRECTORY%/}/" ]; then
        if ! cd "$INM_BASE_DIRECTORY"; then
            log err "[ENV] Failed to enter derived base directory: $INM_BASE_DIRECTORY"
            exit 1
        fi
        log debug "[ENV] Changed into derived base directory: $INM_BASE_DIRECTORY"
    fi

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
            if declare -F should_suppress_pre_switch_logs >/dev/null 2>&1 && should_suppress_pre_switch_logs; then
                log debug "[ENV] Using local .inmanage/.env.inmanage at $INM_SELF_ENV_FILE"
            else
                log info "[ENV] Using local .inmanage/.env.inmanage at $INM_SELF_ENV_FILE"
            fi
        elif [ -n "${INM_BASE_DIRECTORY:-}" ] && [ -f "${INM_BASE_DIRECTORY%/}/.inmanage/.env.inmanage" ]; then
            INM_SELF_ENV_FILE="${INM_BASE_DIRECTORY%/}/.inmanage/.env.inmanage"
            if declare -F should_suppress_pre_switch_logs >/dev/null 2>&1 && should_suppress_pre_switch_logs; then
                log debug "[ENV] Using base .inmanage/.env.inmanage at $INM_SELF_ENV_FILE"
            else
                log info "[ENV] Using base .inmanage/.env.inmanage at $INM_SELF_ENV_FILE"
            fi
        fi
    fi

    if [ -z "${INM_SELF_ENV_FILE:-}" ] || [ ! -f "$INM_SELF_ENV_FILE" ]; then
        log note "[ENV] Project config file not found."

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

    persist_derived_config

    # Config was found or created – validate and load
    if [ ! -r "$INM_SELF_ENV_FILE" ]; then
        log err "[ENV] Project config file '$INM_SELF_ENV_FILE' is not readable. Aborting."
        exit 1
    fi

    log debug "[ENV] Loading project configuration from: $INM_SELF_ENV_FILE"
    load_env_file_raw "$INM_SELF_ENV_FILE" || {
        log err "[ENV] Failed to load project configuration."
        exit 1
    }
    if declare -F should_suppress_pre_switch_logs >/dev/null 2>&1 && should_suppress_pre_switch_logs; then
        log debug "[ENV] Inmanage CLI config loaded: ${INM_SELF_ENV_FILE}"
    else
        log info "[ENV] Inmanage CLI config loaded: ${INM_SELF_ENV_FILE}"
    fi

    # Expand placeholders in key paths after all loads (allows ${INM_BASE_DIRECTORY} style) without eval
    expand_placeholders() {
        local input="$1"
        # replace ${VAR} by value of VAR from current environment
        local output="$input"
        while [[ "$output" =~ (\$\{([^}]+)\}) ]]; do
            local full="${BASH_REMATCH[1]}"
            local var="${BASH_REMATCH[2]}"
            local val
            if [[ "$var" == "HOME" && -n "${INM_ORIGINAL_HOME:-}" ]]; then
                val="$INM_ORIGINAL_HOME"
            else
                val="${!var}"
            fi
            output="${output//$full/$val}"
        done
        printf "%s" "$output"
    }
    path_expand_no_eval() {
        local p="$1"
        [[ -z "$p" ]] && { printf "%s" "$p"; return; }
        p="$(expand_placeholders "$p")"
        local home_base="${INM_ORIGINAL_HOME:-$HOME}"
        p="${p/#\~/$home_base}"
        p="${p//\$\{HOME\}/$home_base}"
        p="${p//\$HOME/$home_base}"
        printf "%s" "$p"
    }
    INM_ENV_FILE="$(path_expand_no_eval "${INM_ENV_FILE:-}")"
    INM_ARTISAN_STRING="$(path_expand_no_eval "${INM_ARTISAN_STRING:-}")"
    INM_PROVISION_ENV_FILE="$(path_expand_no_eval "${INM_PROVISION_ENV_FILE:-}")"
    INM_SELF_ENV_FILE="$(path_expand_no_eval "${INM_SELF_ENV_FILE:-}")"
    INM_CACHE_GLOBAL_DIRECTORY="$(path_expand_no_eval "${INM_CACHE_GLOBAL_DIRECTORY:-}")"
    INM_CACHE_LOCAL_DIRECTORY="$(path_expand_no_eval "${INM_CACHE_LOCAL_DIRECTORY:-}")"
    INM_BACKUP_DIRECTORY="$(path_expand_no_eval "${INM_BACKUP_DIRECTORY:-}")"

    # Normalize base dir to always carry a trailing slash for consistent concatenation.
    if declare -F ensure_trailing_slash >/dev/null && [ -n "${INM_BASE_DIRECTORY:-}" ]; then
        INM_BASE_DIRECTORY="$(ensure_trailing_slash "$INM_BASE_DIRECTORY")"
        log debug "[ENV] Normalized base directory: $INM_BASE_DIRECTORY"
    fi

    # Normalize installation path in case INM_INSTALLATION_DIRECTORY is absolute.
    if declare -F compute_installation_path >/dev/null; then
        INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
        local env_state=""
        if [[ -n "${INM_ENV_FILE:-}" ]] && declare -F file_read_state >/dev/null 2>&1; then
            env_state="$(file_read_state "$INM_ENV_FILE")"
        fi
        if [[ "$env_state" == "exists_unreadable" || "$env_state" == "permission" ]]; then
            if declare -F should_suppress_pre_switch_logs >/dev/null 2>&1 && should_suppress_pre_switch_logs; then
                log debug "[ENV] App .env not readable: $INM_ENV_FILE (permission issue)."
            else
                log warn "[ENV] App .env not readable: $INM_ENV_FILE (permission issue)."
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

    if declare -F maybe_migrate_legacy_cli >/dev/null 2>&1; then
        maybe_migrate_legacy_cli "$@" || exit 1
    fi

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

    check_missing_settings
    check_provision_file
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
    if [ -n "$elevated_username" ]; then
        log info "[PVF] Elevated SQL user '$elevated_username' found."

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
# ---------------------------------------------------------------------
# check_gh_credentials()
# Determines curl auth flag based on INM_GH_API_CREDENTIALS.
# ---------------------------------------------------------------------
check_gh_credentials() {
    # Only set CURL_AUTH_FLAG for commands that actually download; keep quiet otherwise.
    if [[ -n "$INM_GH_API_CREDENTIALS" && "$INM_GH_API_CREDENTIALS" == *:* ]]; then
        # shellcheck disable=SC2034
        CURL_AUTH_FLAG="-u $INM_GH_API_CREDENTIALS"
        log debug "[GH] Credentials detected. Curl commands will include them."
    else
        # shellcheck disable=SC2034
        CURL_AUTH_FLAG=""
        log debug "[GH] No credentials set. If curl connections fail, try to add credentials."
    fi
}
