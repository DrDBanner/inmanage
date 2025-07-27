#!/usr/bin/env bash

set -e

# todo#: auf neue .env.project.inmanage locations prüfen, nicht mehr hart codiert.
[[ -n "$BASH_VERSION" ]] || {
    log err "[shell] This script requires Bash."

    if [ -f ".inmanage/.env.inmanage" ]; then
        user=$(grep '^INM_ENFORCED_USER=' .inmanage/.env.inmanage | cut -d= -f2 | tr -d '"')
        log info "[shell] Try: sudo -u ${user:-{your-user}} bash ./inmanage.sh"
    else
        log info "[shell] Try: sudo -u {your-user} bash ./inmanage.sh"
    fi

    exit 1
}

## Self configuration
INM_SELF_ENV_FILE=""
INM_PROVISION_ENV_FILE=""
INM_ENV_EXAMPLE_FILE=""
CURL_AUTH_FLAG=""
SCRIPT_PATH="$0"
SCRIPT_NAME=$(basename "$0")


## Bling Bling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    MAGENTA=$(tput setaf 5)
    CYAN=$(tput setaf 6)
    WHITE=$(tput setaf 7)
    GRAY=$(tput setaf 8)  # meist hellgrau, abhängig vom Terminal
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''; GRAY=''; BOLD=''; RESET=''
fi

log() {
    local type="$1"; shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    case "$type" in
        debug)
            if [ "$DEBUG" = true ]; then
                printf "${CYAN}%s [DEBUG] %s${RESET}\n" "$timestamp" "$*" >&2
            fi
            ;;
        info)
            printf "${WHITE}%s [INFO] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        note)
            local count=$#
            local i=1
            for arg in "$@"; do
                if [ "$i" -lt "$count" ]; then
                    printf "${WHITE}%s %s${RESET}" $'' "$arg" >&2
                else
                    printf "${WHITE}%s %s${RESET}\n" $'' "$arg" >&2
                fi
                ((i++))
            done
            ;;
        docs)
            printf "${GREEN}%s %s${RESET}\n" "$*" >&2
            ;;
        ok)
            printf "${GREEN}%s [OK] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        warn)
            printf "${MAGENTA}%s [WARN] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        important)
            printf "${MAGENTA}%s [IMPORTANT] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        err)
            printf "${RED}%s [ERR] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        bold)
            printf "${BOLD}%s [BOLD] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        *)
            echo "$*" >&2
            ;;
    esac
}
declare -A default_settings=(
    ["INM_BASE_DIRECTORY"]="$PWD/"
    ["INM_INSTALLATION_DIRECTORY"]="./invoiceninja"
    ["INM_ENV_FILE"]="\${INM_BASE_DIRECTORY}\${INM_INSTALLATION_DIRECTORY}/.env"
    ["INM_CACHE_LOCAL_DIRECTORY"]="./.cache"
    ["INM_CACHE_GLOBAL_DIRECTORY"]="$HOME/.cache/inmanage"
    ["INM_CACHE_GLOBAL_RETENTION"]="3"
    ["INM_DUMP_OPTIONS"]="--default-character-set=utf8mb4 --no-tablespaces --skip-add-drop-table --quick --single-transaction"
    ["INM_BACKUP_DIRECTORY"]="./_backups"
    ["INM_FORCE_READ_DB_PW"]="N"
    ["INM_ENFORCED_USER"]="www-data"
    ["INM_ENFORCED_SHELL"]="$(command -v bash)"
    ["INM_PHP_EXECUTABLE"]="$(command -v php)"
    ["INM_ARTISAN_STRING"]="\${INM_PHP_EXECUTABLE} \${INM_BASE_DIRECTORY}\${INM_INSTALLATION_DIRECTORY}/artisan"
    ["INM_PROGRAM_NAME"]="InvoiceNinja"
    ["INM_COMPATIBILITY_VERSION"]="5+"
    ["INM_KEEP_BACKUPS"]="2"
    ["INM_GH_API_CREDENTIALS"]="0"
)

prompt_order=(
    "INM_BASE_DIRECTORY"
    "INM_INSTALLATION_DIRECTORY"
    "INM_DUMP_OPTIONS"
    "INM_BACKUP_DIRECTORY"
    "INM_KEEP_BACKUPS"
    "INM_FORCE_READ_DB_PW"
    "INM_ENFORCED_USER"
    "INM_ENFORCED_SHELL"
    "INM_PHP_EXECUTABLE"
    "INM_GH_API_CREDENTIALS"
)
declare -A prompt_texts=(
    ["INM_BASE_DIRECTORY"]="Which shall be your base-directory? Must have a trailing slash."
    ["INM_INSTALLATION_DIRECTORY"]="The current/future Invoice Ninja folder? Must be relative from \$INM_BASE_DIRECTORY and can start with a . dot."
    ["INM_DUMP_OPTIONS"]="Modify database dump options: In doubt, keep defaults."
    ["INM_BACKUP_DIRECTORY"]="Backup Directory?"
    ["INM_FORCE_READ_DB_PW"]="Include DB password in CLI? (Y): Convenient, but may expose the password to other server users during runtime. (N): Assumes a secure .my.cnf file with credentials to avoid exposure."
    ["INM_ENFORCED_USER"]="Script user? Usually the webserver user. Ensure it matches your webserver setup."
    ["INM_ENFORCED_SHELL"]="Which shell should be used? In doubt, keep as is."
    ["INM_PHP_EXECUTABLE"]="Path to the PHP executable? In doubt, keep as is."
    ["INM_KEEP_BACKUPS"]="Backup retention? Set to 2 for daily backups to keep 2 snapshots. Ensure enough disk space."
    ["INM_GH_API_CREDENTIALS"]="GitHub API credentials may be required on shared hosting. Use the format username:password or token:x-oauth. If provided, all curl commands will use these credentials;"
)
prompt_var() {
    # Parameters:
    #   $1 = var (variable name)
    #   $2 = default (default value)
    #   $3 = text (optional: prompt text, defaults to prompt_texts[$var])
    #   $4 = silent (optional: if true, input is hidden, defaults to false)
    #   $5 = timeout (optional: timeout in seconds, defaults to 60)
    #
    # Usage example:
    #   username=$(prompt_var "username" "admin" "Enter username:")
    #   password=$(prompt_var "db_pass" "" "Enter DB password:" true 30)

    local var="$1"
    local default="$2"
    local text="${3:-${prompt_texts[$var]}}"
    local silent="${4:-false}"
    local timeout="${5:-60}"
    local input=""

    local prompt="${GREEN}\n${text}\n${RESET}${GRAY}[$default]${RESET} > "

    local read_opts=(-r -t "$timeout" -p "$prompt")
    [[ "$silent" == "true" ]] && read_opts+=(-s)

    # shellcheck disable=SC2162
    if read "${read_opts[@]}" input; then
        echo "${input:-$default}"
    else
        echo   # newline
        log err "[PROMPT] Timeout after ${timeout}s – no input received"
        return 1
    fi
}

    # shellcheck disable=SC2059
print_logo() {
    printf "${BLUE}"
    printf "    _____   __                                       __\n"
    printf "   /  _/ | / /___ ___  ____ _____  ____ _____ ____  / /\n"
    printf "   / //  |/ / __ \`__ \\/ __ \`/ __ \\/ __ \`/ __ \`/ _ \\/ / \n"
    printf " _/ // /|  / / / / / / /_/ / / / / /_/ / /_/ /  __/_/  \n"
    printf "/___/_/ |_/_/ /_/ /_/\\__,_/_/ /_/\\__,_/\\__, /\\___(_)   \n"
    printf "                                      /____/           ${RESET}\n"
    printf "${BLUE}${BOLD}ULTIMATE - INVOICE NINJA - MANAGEMENT SCRIPT${RESET}\n${GREEN}${BOLD}(c) by Dr.D.Banner ${RESET}\n\n"
    printf "\n\n"
}
detect_mysql_collation() {
  local host="$1"
  local port="$2"
  local user="$3"
  local pass="$4"

  local collation
  collation=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" -Nse "SHOW VARIABLES LIKE 'collation_server';" 2>/dev/null | awk '{print $2}')

  if [ -n "$collation" ]; then
    if ! mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "CREATE DATABASE __inm_check COLLATE $collation;" 2>/dev/null; then
      log warn "[db] Server collation '$collation' not valid for CREATE DATABASE. Falling back."
      collation=""
    else
      mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "DROP DATABASE __inm_check;" 2>/dev/null
    fi
  fi

  if [ -z "$collation" ]; then
    collation="utf8mb4_unicode_ci"
    log debug "[db] Using fallback collation: $collation"
  fi
  echo "$collation"
}
# shellcheck disable=SC2154
import_database() {

    # ---------------------------------------------------------------------
    # import_database()
    #
    # Imports a SQL dump into the configured Invoice Ninja database.
    #
    # Behavior:
    # - Uses DB credentials from .env or attempts .my.cnf authentication.
    # - If INM_FORCE_READ_DB_PW="Y", the password may get exposed to other users on the server during import.
    # - If .my.cnf fails and INM_FORCE_READ_DB_PW="N", user will be securely prompted.
    # - Creates a timestamped database backup before import -if there were tables in the DB.
    # - Drops all existing tables after backup and before import.
    #
    # Parameters:
    #   --file=<path>     Path to the SQL dump to import (required)
    #   --force           Skip confirmation prompt and overwrite DB contents
    #
    # Globals:
    #   INM_FORCE_READ_DB_PW    = Y/N, controls password handling via .env.inmanage
    #   INM_DUMP_OPTIONS        = mysqldump options (e.g., charset, transaction)
    #   DB_HOST, DB_USERNAME, DB_PASSWORD, DB_DATABASE = Loaded from Invoice Ninja .env
    #
    # Notes:
    #   - Import replaces the entire database. Proceed with caution.
    #   - Password on CLI (when forced) may expose credentials during runtime.
    #
    # Example:
    #   import_database --file=/mnt/backup/latest.sql --force
    # ---------------------------------------------------------------------


    declare -A ARGS
    parse_named_args ARGS "$@"

    local file="${ARGS[file]}"
    local force="${ARGS[force]:-false}"

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        log err "[IMPORT] Please provide a valid --file path to a .sql dump"
        return 1
    fi

    log info "[IMPORT] Starting import of: $file"

  # Determine DB access method

    local db_mode
    # shellcheck disable=SC2153  
    if [ "$INM_FORCE_READ_DB_PW" = "Y" ]; then
        db_mode="env"
    elif mysql --connect-timeout=3 -u"$DB_USERNAME" -h"$DB_HOST" "$DB_DATABASE" -e "SELECT 1;" >/dev/null 2>&1; then
        db_mode="mycnf"
    else
        log warn "[IMPORT] .my.cnf auth failed or not present"
        log note "[SECURITY] Prompting for password (interactive mode)."
        log note "[SECURITY] Convenient, but may expose the password to other server users during runtime"

        INM_PROMPTED_PASSWORD=$(prompt_var "DB_PASSWORD" "" "Enter DB password for '$DB_USERNAME'" true 60)
        [ -z "$INM_PROMPTED_PASSWORD" ] && {
            log err "[IMPORT] No password entered. Aborting."
            return 1
        }
        db_mode="prompt"
    fi


    # Define mysql/mysqldump wrappers
    mysql_cmd() {
        case "$db_mode" in
            env)    mysql -u"$DB_USERNAME" -p"$DB_PASSWORD" -h"$DB_HOST" "$@" ;;
            mycnf)  mysql "$@" ;;
            prompt) mysql -u"$DB_USERNAME" -p"$INM_PROMPTED_PASSWORD" -h"$DB_HOST" "$@" ;;
        esac
    }

    mysqldump_cmd() {
        # Convert INM_DUMP_OPTIONS string to array to avoid word splitting or globbing
        local -a dump_opts=()
        if [[ -n "$INM_DUMP_OPTIONS" ]]; then
            read -r -a dump_opts <<< "$INM_DUMP_OPTIONS"
        fi

        case "$db_mode" in
            env)
                mysqldump -u"$DB_USERNAME" -p"$DB_PASSWORD" -h"$DB_HOST" "${dump_opts[@]}" "$@"
                ;;
            mycnf)
                mysqldump "${dump_opts[@]}" "$@"
                ;;
            prompt)
                mysqldump -u"$DB_USERNAME" -p"$INM_PROMPTED_PASSWORD" -h"$DB_HOST" "${dump_opts[@]}" "$@"
                ;;
        esac
    }

    # Check for existing data
    local table_count
    table_count=$(mysql_cmd "$DB_DATABASE" -e "SHOW TABLES;" 2>/dev/null | tail -n +2 | wc -l)

    if [ "$table_count" -gt 0 ]; then
        if [ "$force" != true ]; then
            local confirm
            confirm=$(prompt_var "CONFIRM" "n" "⚠️ Database '$DB_DATABASE' is NOT empty. Overwrite contents?" false 60)
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log err "[IMPORT] Cancelled by user"
                return 1
            fi
        fi

        # Backup existing
        local timestamp
        timestamp=$(date +"%Y%m%d-%H%M%S")
        local backup_file="db-backup-$timestamp.sql"
        log info "[IMPORT] Backing up existing DB to: $backup_file"
        if ! mysqldump_cmd "$DB_DATABASE" > "$backup_file"; then
            log warn "[IMPORT] Backup failed. Proceeding anyway."
        fi

        # Drop all tables
        log info "[IMPORT] Dropping all existing tables in: $DB_DATABASE"
        local drop_sql
        drop_sql=$(mysql_cmd "$DB_DATABASE" -Bse "SHOW TABLES;" | awk '{print "DROP TABLE IF EXISTS \`" $1 "\`;"}')
        echo "$drop_sql" | mysql_cmd "$DB_DATABASE"
    fi

    # Import new dump
    log info "[IMPORT] Importing new data from: $file"
    if ! mysql_cmd "$DB_DATABASE" < "$file"; then
        log err "[IMPORT] Failed to import SQL dump"
        return 1
    fi

    log ok "[IMPORT] Database '$DB_DATABASE' successfully restored"
}
create_database() {
    # ---------------------------------------------------------------------
    # create_database()
    #
    # This function is automatically called by the unattended installation process.
    # So, not really neccessary to be called manually.
    #
    # Creates a MySQL database and user using elevated credentials. Values are
    # resolved in order: passed arguments ($1/$2), named arguments (--db_*),
    # or fallback to environment variables (e.g. DB_HOST, DB_USERNAME).
    # Automatically determines server collation and applies user privileges.
    # Removes elevated credentials from the provision file after success.
    #
    # Behavior:
    # - Loads DB_* and elevated credentials from provision file if present
    # - Resolves credentials and connection details via named args or environment
    # - Validates all required values and warns if any are missing
    # - Detects recommended collation via detect_mysql_collation()
    # - Creates database if missing and grants permissions (localhost and remote)
    # - Removes DB_ELEVATED_* entries from provision file after success
    #
    # Parameters:
    #   $1                     Elevated SQL username (optional, overrides env/named)
    #   $2                     Elevated SQL password (optional, overrides env/named)
    #
    # Named Arguments:
    #   --db_host              MySQL host (default: localhost)
    #   --db_port              MySQL port (default: 3306)
    #   --db_name              Target database name
    #   --db_user              Database user to create
    #   --db_pass              Password for created user
    #
    # Globals:
    #   INM_PROVISION_ENV_FILE, NAMED_ARGS, DB_*, DB_ELEVATED_*
    #
    # Example:
    #   create_database root s3cret --db_name=foo --db_user=theuser --db_pass=thepass
    # ---------------------------------------------------------------------


    log debug "[db] Creating database and user..."
    
    if [ -f "$INM_PROVISION_ENV_FILE" ]; then
            load_env_file_raw "$INM_PROVISION_ENV_FILE" || {
        log err "[PVF] Failed to load DB variables from $INM_PROVISION_ENV_FILE"
        exit 1
        }
    fi

    local elevated_user="${1:-${DB_ELEVATED_USERNAME}}"
    local elevated_pass="${2:-${DB_ELEVATED_PASSWORD}}"
    local db_host="${NAMED_ARGS[db_host]:-${DB_HOST:-localhost}}"
    local db_port="${NAMED_ARGS[db_port]:-${DB_PORT:-3306}}"
    local db_name="${NAMED_ARGS[db_name]:-$DB_DATABASE}"
    local db_user="${NAMED_ARGS[db_user]:-$DB_USERNAME}"
    local db_pass="${NAMED_ARGS[db_pass]:-$DB_PASSWORD}"
    local force="${NAMED_ARGS[force]:-false}"
    local debug_keep_tmp="${NAMED_ARGS[debug_keep_tmp]:-false}"


    log debug "[db] Using DB credentials: host=$db_host, port=$db_port, name=$db_name, user=$db_user"

    # Validate all required variables
    local missing_vars=()
    for var in elevated_user elevated_pass db_host db_port db_name db_user db_pass; do
        if [ -z "${!var}" ]; then
            log warn "[db] Missing DB variable: $var; Set it in the environment or pass it as an argument."
            missing_vars+=("$var")
        else
            log debug "[db] DB variable $var is set to '${!var}'"
        fi
    done

    if [ "${#missing_vars[@]}" -gt 0 ]; then
        log debug "[db] Required DB variables missing: ${missing_vars[*]}"
        #exit 1
    fi

    # Detect collation or fallback
    local collation
    if type -t detect_mysql_collation >/dev/null; then
        collation=$(detect_mysql_collation "$db_host" "$db_port" "$elevated_user" "$elevated_pass")
    fi
    [ -z "$collation" ] && collation="utf8mb4_unicode_ci"
    log debug "[db] Using collation: $collation"

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
parse_named_args() {
    declare -n _target="$1"
    shift
    for arg in "$@"; do
        if [[ "$arg" == --* ]]; then
            key="${arg%%=*}"
            key="${key#--}"
            key="${key//-/_}"    # Convert dashes to underscores
            value="${arg#*=}"
            _target["$key"]="$value"
        fi
    done

    if [[ "$DEBUG" = true ]]; then
        for k in "${!_target[@]}"; do
            printf "[DEBUG][PNA] NAMED_ARGS[%s]=%s\n" "$k" "${_target[$k]}" >&2
        done
    fi
}

check_base_directory_valid_and_enter() {
    log debug "[DIR] Checking base directory: $INM_BASE_DIRECTORY"
    if [ -z "$INM_BASE_DIRECTORY" ]; then
        log note "Please provide --base-directory=/your/path or use --ninja-location=/your/path. Alternatively, start a new installation with: $SCRIPT_NAME install"
        log note "Need help? Try: $SCRIPT_NAME --help"
        return 1
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
check_provision_file() {
    # todo: Checken, dass wenn force ist, dass nicht angehängt, sondern neu geschrieben wird.
    # todo Überprüfen warum schleife 2 mal läuft.
    if [ ! -f "$INM_PROVISION_ENV_FILE" ]; then
        log debug "[PVF] No provision file found. Skipping provisioning."
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
    if [ "$force_update" != true ]; then
    log info "[PVF] You have 10 seconds to cancel this operation if you do not want to run the provision."
        sleep 10
    fi

    local elevated_username="${DB_ELEVATED_USERNAME:-}"
    local elevated_password="${DB_ELEVATED_PASSWORD:-}"
    if [ -n "$elevated_username" ]; then
        log info "[PVF] Elevated SQL user '$elevated_username' found."

        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e 'quit' 2>/dev/null; then
            log ok "[PVF] Connection with elevated credentials successful."

            if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e "USE \`$DB_DATABASE\`;" 2>/dev/null; then
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

            if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e 'quit' 2>/dev/null; then
                log ok "[PVF] Retry successful with prompted password."

                if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e "USE \`$DB_DATABASE\`;" 2>/dev/null; then
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

        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e 'quit' 2>/dev/null; then
            if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "USE \`$DB_DATABASE\`;" 2>/dev/null; then
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
persist_derived_config() {
    # ---------------------------------------------------------------------
    # persist_derived_config()
    #
    # Writes the current values from `default_settings` to a new config file
    # if no existing `.env.inmanage` is present and auto-creation is allowed.
    #
    # This enables auto-detection of Invoice Ninja installations even
    # without manual configuration.
    #
    # Globals:
    #   INM_SELF_ENV_FILE, NAMED_ARGS, default_settings
    #
    # Requires:
    #   NAMED_ARGS[auto_create_config] == true
    #   INM_SELF_ENV_FILE must be set (or defaulted)
    # ---------------------------------------------------------------------
    log debug "[PDC] Attempting to persist default configuration"

    if [ "${NAMED_ARGS[auto_create_config]}" != true ]; then
        log debug "[PDC] Skipped: auto_create_config is not true"
        return 0
    fi

    INM_SELF_ENV_FILE="${NAMED_ARGS[config]:-${INM_SELF_ENV_FILE:-.inmanage/.env.inmanage}}"
    local target_dir
    target_dir="$(dirname "$INM_SELF_ENV_FILE")"

    mkdir -p "$target_dir" 2>/dev/null || {
        log err "[PDC] Could not create config target directory: $target_dir"
        return 1
    }

    if [ -f "$INM_SELF_ENV_FILE" ]; then
        log note "[PDC] Config already exists: $INM_SELF_ENV_FILE. Skipping auto-persist."
        return 0
    fi

    touch "$INM_SELF_ENV_FILE" 2>/dev/null || {
        log err "[PDC] Failed to create config file: $INM_SELF_ENV_FILE"
        return 1
    }

    log info "[PDC] Writing derived config to: $INM_SELF_ENV_FILE"

    for key in "${!default_settings[@]}"; do
        echo "$key=\"${default_settings[$key]}\"" >> "$INM_SELF_ENV_FILE"
    done

    chmod 600 "$INM_SELF_ENV_FILE" 2>/dev/null
    log ok "[PDC] Config persisted successfully"

    return 0
}
select_from_candidates() {
    local prompt="$1"
    shift
    local options=("$@")

    local count="${#options[@]}"
    if [ "$count" -eq 0 ]; then
        log err "[SEL] No selectable candidates available."
        return 1
    fi

    echo -e "\n${CYAN}${prompt}${RESET}"
    for i in "${!options[@]}"; do
        printf "  [%d] %s\n" "$((i + 1))" "${options[$i]}"
    done

    local choice
    while true; do
        echo -ne "${YELLOW}Enter number [1-$count] or Ctrl+C to cancel: ${RESET}"
        read -r choice
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            local selected="${options[$((choice - 1))]}"
            log ok "[SEL] Selected: $selected"
            printf "%s\n" "$selected"
            return 0
        else
            log warn "[SEL] Invalid choice: $choice"
        fi
    done
}
resolve_script_path() {
    local target="$1"

    # Linux, macOS with coreutils
    if command -v realpath >/dev/null 2>&1; then
        realpath "$target" && return
    fi

    # Linux only
    if readlink -f "$target" >/dev/null 2>&1; then
        readlink -f "$target" && return
    fi

    # Posix compliant fallback
    (
        cd "$(dirname "$target")" 2>/dev/null || exit 1
        local file="$(basename "$target")"
        # if symlink, resolve it
        while [ -L "$file" ]; do
            file="$(readlink "$file")"
            cd "$(dirname "$file")" 2>/dev/null || break
            file="$(basename "$file")"
        done
        printf "%s/%s\n" "$(pwd -P)" "$file"
    )
}
resolve_env_paths() {
    # ---------------------------------------------------------------------
    # resolve_env_paths()
    # inmanage – environment and configuration resolution
    #
    # Determines configuration and context for execution.
    #
    # Configuration can be provided via:
    #   --config=/absolute/path/to/.env.projectname.inmanage     # static config
    #   --ninja-location=/absolute/path/to/invoiceninja          # infer from .env
    #
    # If neither is provided, the script scans for usable config files:
    #   1. $PWD/.inmanage/.env
    #   2. $PWD/.env
    #   3. $PWD/../.inmanage/.env
    #   4. $PWD/../.env
    #   5. $HOME/.inmanage/.env
    #
    # If a single match is found, it is used automatically.
    # If multiple candidates are found:
    #   - the user is prompted to select one (unless --force is passed)
    #   - with --force and multiple matches, the process aborts
    #
    # Sets:
    #   INM_SELF_ENV_FILE         → static .env.*.inmanage config (if used)
    #   INM_ENV_FILE              → actual .env of Invoice Ninja installation
    #   INM_BASE_DIRECTORY        → base path (parent of install)
    #   INM_INSTALLATION_DIRECTORY → installation folder (relative)
    # ---------------------------------------------------------------------

    log debug "[RES] Resolving environment paths..."

    unset -v INM_SELF_ENV_FILE INM_PROVISION_ENV_FILE INM_ENV_FILE INM_BASE_DIRECTORY INM_INSTALLATION_DIRECTORY

    # Explicit override: --ninja-location
    if [ -n "${NAMED_ARGS[ninja_location]}" ]; then
        local ninja_dir="${NAMED_ARGS[ninja_location]}"
        if [ ! -f "$ninja_dir/.env" ]; then
            log err "[RES] No .env found in --ninja-location: $ninja_dir"
            exit 1
        fi
        INM_BASE_DIRECTORY="$(dirname "$(realpath "$ninja_dir")")/"
        INM_INSTALLATION_DIRECTORY="$(basename "$ninja_dir")"
        INM_ENV_FILE="$ninja_dir/.env"
        log ok "[RES] Using .env from --ninja-location: $INM_ENV_FILE"
        return 0
    fi

    local candidate_paths=(
        "$PWD/.inmanage"
        "$PWD"
        "$PWD/../.inmanage"
        "$PWD/.."
        "$HOME/.inmanage"
    )

    local candidates=()
    for dir in "${candidate_paths[@]}"; do
        [ -f "$dir/.env" ] && candidates+=("$dir/.env")
    done

    if [ ${#candidates[@]} -eq 0 ]; then
        log err "[RES] Could not find a usable .env file. Please specify --ninja-location=…"
        exit 1
    elif [ ${#candidates[@]} -eq 1 ]; then
        INM_ENV_FILE="${candidates[0]}"
        log debug "[RES] Found .env: $INM_ENV_FILE"
    else
        if [ "${NAMED_ARGS[force]}" = true ]; then
            log err "[RES] Multiple .env files found, but --force was used. Cannot decide."
            exit 1
        fi
        INM_ENV_FILE="$(select_from_candidates "Select your Invoice Ninja .env file:" "${candidates[@]}")" || exit 1
    fi

    INM_BASE_DIRECTORY="$(dirname "$(dirname "$INM_ENV_FILE")")/"
    INM_INSTALLATION_DIRECTORY="$(basename "$(dirname "$INM_ENV_FILE")")"

    log ok "[RES] Detected base: $INM_BASE_DIRECTORY"
    log ok "[RES] Detected install dir: $INM_INSTALLATION_DIRECTORY"
    log ok "[RES] Using: $INM_ENV_FILE"
}
resolve_cache_directory() {
    # Returns a cache path, preferring global cache if allowed
    if check_global_cache_permissions; then
        echo "${INM_CACHE_GLOBAL_DIRECTORY}"
    else
        echo "${INM_CACHE_LOCAL_DIRECTORY}"
    fi
}
resolve_global_cache_dir() {
    # ---------------------------------------------------------------------
    # resolve_global_cache_dir()
    # inmanage – determine usable global cache directory for tar.gz etc.
    #
    # Tries user-specific cache first:       $HOME/.cache/inmanage
    # Falls back to system-wide cache:       /var/cache/inmanage (sudo)
    #
    # On failure, exits unless --offline or --skip-cache is set (TBD)
    #
    # Sets:
    #   INM_GLOBAL_CACHE       → usable directory for downloads
    # ---------------------------------------------------------------------

    local user_cache="${HOME}/.cache/inmanage"
    local root_cache="/var/cache/inmanage"

    log debug "[GC] Resolving global cache directory..."

    if [ -w "$user_cache" ]; then
        INM_GLOBAL_CACHE="$user_cache"
        log ok "[GC] Using user cache: $INM_GLOBAL_CACHE"
        return 0
    fi

    log warn "[GC] User cache not writable: $user_cache"

    if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        log note "[GC] Attempting sudo access for: $root_cache (timeout 20s)"
        if timeout 20 sudo mkdir -p "$root_cache" && timeout 20 sudo chown "$USER" "$root_cache"; then
            INM_GLOBAL_CACHE="$root_cache"
            log ok "[GC] Using system cache: $INM_GLOBAL_CACHE"
            return 0
        else
            log err "[GC] Failed to set up writable system cache at $root_cache"
            exit 1
        fi
    else
        log err "[GC] No writeable global cache available and no sudo rights."
        exit 1
    fi
}
check_global_cache_permissions() {
    local dir="${INM_CACHE_GLOBAL_DIRECTORY:-$HOME/.cache/inmanage}"
    if [ -w "$dir" ]; then
        return 0
    elif [ ! -e "$dir" ]; then
        log note "[CACHE] Global cache does not exist. Attempting to create: $dir"
        timeout 20s sudo mkdir -p "$dir" && sudo chmod 755 "$dir" && return 0
    else
        log warn "[CACHE] Global cache is not writable: $dir"
    fi
    return 1
}
enforce_user_switch() {
    # ============================================================
    # enforce_user_switch
    # ------------------------------------------------------------
    # Checks if a user switch is required (via --user= argument)
    # and switches to the specified user using sudo.
    #
    # Default behavior: remain as the switched user (“stay” mode).
    # Only if --switchback is provided, the script will return
    # to the original user after execution.
    #
    # Internal flag: __INTERNAL_SWITCHED_FROM_USER
    # ------------------------------------------------------------
    #
    # Usage:
    #   enforce_user_switch "$@"
    # ============================================================

    local -A args=()
    parse_named_args args "$@"

    local providedargs=("$@")

    if [ -z "${args[user]}" ]; then
        log debug "[ENV] No --user specified, staying as $(whoami)."
    elif [ "$(whoami)" = "${args[user]}" ]; then
        log debug "[ENV] Already running as ${args[user]}, no switch required."
    fi


    # === Switch to target user if required ===
    if [ -n "${args[user]}" ] && [ "$(whoami)" != "${args[user]}" ]; then
        unset __INTERNAL_SWITCHED_FROM_USER
        # shellcheck disable=SC2155
        export __INTERNAL_SWITCHED_FROM_USER="$(whoami)"

        local memyselfasscript
        memyselfasscript="$(resolve_script_path "$0")"

        log info "[ENV] Switching to user '${args[user]}'."
        log debug "[ENV] If you don't want to switch users, put your current user into the INM_ENFORCED_USER variable in your config file."

        exec sudo -u "${args[user]}" -- bash "$memyselfasscript" "${providedargs[@]}"
    fi

    # === Switch back if explicitly requested ===
    if [ -n "${args[switchback]}" ] && [ -n "$__INTERNAL_SWITCHED_FROM_USER" ]; then
        log info "[ENV] Switching back to user '$__INTERNAL_SWITCHED_FROM_USER'."

        local memyselfasscript
        memyselfasscript="$(resolve_script_path "$0")"

        local old_from="$__INTERNAL_SWITCHED_FROM_USER"
        unset __INTERNAL_SWITCHED_FROM_USER

        exec sudo -u "$old_from" -- bash "$memyselfasscript" "${providedargs[@]}"
    fi
}
check_envs() {
    log debug "[ENV] Check starts."

    check_base_directory_valid_and_enter || {
        log err "[ENV] Base directory check failed. Aborting."
        exit 1
    }
    resolve_env_paths

    if [ ! -f "$INM_SELF_ENV_FILE" ]; then
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
check_missing_settings() {
    updated=0
    for key in "${!default_settings[@]}"; do
        if ! grep -q "^$key=" "$INM_SELF_ENV_FILE"; then
            log warn "[CMS] $key not found in $INM_SELF_ENV_FILE. Adding with default value '${default_settings[$key]}'."
            echo "$key=\"${default_settings[$key]}\"" >> "$INM_SELF_ENV_FILE"
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
check_commands() {
    local commands=("curl" "wc" "tar" "cp" "mv" "mkdir" "chown" "find" "rm" "mysqldump" "mysql" "grep" "xargs" "php" "touch" "sed" "sudo" "tee" "rsync" "awk" "jq" "git" "composer")
    local missing_commands=()

    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done

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
load_env_file_raw() {
    local file="$1"
    log debug "[ENV] Loading relevant vars from: $file"

    local tmpfile
    tmpfile=$(mktemp /tmp/.inm_env_XXXXXX) || {
        log err "[ENV] Failed to create temp file"
        return 1
    }
    chmod 600 "$tmpfile"

    awk '
        /^[[:space:]]*(DB_|ELEVATED_|NINJA_|PDF_|INM_)[A-Z_]*=/ {
            key = substr($0, 1, index($0, "=") - 1)
            val = substr($0, index($0, "=") + 1)
            sub(/#.*/, "", val)                             # remove inline comment
            gsub(/^[ \t]+|[ \t]+$/, "", val)                # trim whitespace
            gsub(/^"+|"+$/, "", val)                        # remove surrounding quotes
            printf("export %s=\"%s\"\n", key, val)
        }
    ' "$file" > "$tmpfile" || {
        log err "[ENV] Failed to parse env vars from $file"
        rm -f "$tmpfile"
        return 1
    }

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
check_gh_credentials() {

    load_env_file_raw "$INM_SELF_ENV_FILE"
    
    if [[ -n "$INM_GH_API_CREDENTIALS" && "$INM_GH_API_CREDENTIALS" == *:* ]]; then
        CURL_AUTH_FLAG="-u $INM_GH_API_CREDENTIALS"
        log info "[GH] Authentication detected. Curl commands will include credentials."
    else
        CURL_AUTH_FLAG=""
        log debug "[GH] No GH credentials set. If connection fails, try to add credentials."
    fi
}
install_self() {
  log debug "[SELF] Checking CLI registration …"

  local default_bin="/usr/local/bin"
  local local_bin="$HOME/.local/bin"
  local source_script
  source_script="$(realpath "$0")"

  local install_dir="${NAMED_ARGS[--target-dir]:-}"
  local install_mode="${NAMED_ARGS[--install-mode]:-}"

  if [[ -z "$install_mode" ]]; then
    echo
    echo "Select installation mode:"
    echo "  [1] Full Install     – system-wide (requires root)"
    echo "  [2] Local Install    – user context (~/.local/bin)"
    echo "  [3] Project Install  – only for this project"
    echo
    prompt_var "INSTALL_MODE" "Mode (1/2/3)" "3"

    # shellcheck disable=SC2153
    install_mode="$INSTALL_MODE"
  fi

  if [[ -z "$install_dir" ]]; then
    case "$install_mode" in
      1) install_dir="/usr/local/share/inmanage" ;;
      2) install_dir="$HOME/.inmanage" ;;
      3) install_dir="$(pwd)/.inmanage" ;;
      *) log err "[SELF] Invalid mode: $install_mode" ; return 1 ;;
    esac
  fi

  log debug "[SELF] Installing to: $install_dir"
  mkdir -p "$install_dir" || { log err "[SELF] Cannot create $install_dir"; return 1; }

  safe_move_or_copy_and_clean "$(dirname "$source_script")" "$install_dir" --mode=copy --clean || {
    log err "[SELF] Failed to copy files"; return 1;
  }

  local bin_source="$install_dir/inmanage.sh"
  local targets=("inmanage" "inm")

  case "$install_mode" in
    1)
      for name in "${targets[@]}"; do
        if [[ -w "$default_bin" ]]; then
          ln -sf "$bin_source" "$default_bin/$name"
        elif command -v sudo &>/dev/null; then
          prompt_var "ROOTPW" "Root password needed to install system-wide" "" silent=true timeout=15 || return 1
          echo "$ROOTPW" | sudo -S ln -sf "$bin_source" "$default_bin/$name"
        else
          log err "[SELF] Cannot write to $default_bin and sudo not available"
          return 1
        fi
      done
      log ok "[SELF] Installed globally in $default_bin"
      ;;
    2)
      mkdir -p "$local_bin"
      for name in "${targets[@]}"; do
        ln -sf "$bin_source" "$local_bin/$name"
      done
      log ok "[SELF] Installed locally in $local_bin"
      if [[ ":$PATH:" != *":$local_bin:"* ]]; then
        log warn "[SELF] Add '$local_bin' to your PATH."
      fi
      ;;
    3)
     if [[ "$install_mode" == "3" ]]; then
         log info "[INSTALL] Mode: Project Install (only for this project)"

         if [[ -z "${INM_BASE_DIRECTORY:-}" || ! -d "$INM_BASE_DIRECTORY" ]]; then
             log debug "[INSTALL] INM_BASE_DIRECTORY is not set or invalid."

            if declare -F resolve_env_paths >/dev/null; then
                 resolve_env_paths || log warn "[INSTALL] Could not auto-resolve environment. Proceeding manually."
            fi
             if [[ -z "${INM_BASE_DIRECTORY:-}" || ! -d "$INM_BASE_DIRECTORY" ]]; then
                 echo
                 prompt_var "INM_BASE_DIRECTORY" "Please enter project base directory" "$PWD"
                 if [[ ! -d "$INM_BASE_DIRECTORY" ]]; then
                     log info "[INSTALL] Creating directory: $INM_BASE_DIRECTORY"
                     mkdir -p "$INM_BASE_DIRECTORY" || {
                         log err "[INSTALL] Failed to create directory: $INM_BASE_DIRECTORY"
                         exit 1
                     }
                 fi
             fi
         fi

         local install_dir="${INM_BASE_DIRECTORY%/}/.inmanage"
         local source_path
         source_path="$(realpath "$0")"

         mkdir -p "$install_dir" || {
             log err "[INSTALL] Could not create project install directory: $install_dir"
             exit 1
         }

         safe_move_or_copy_and_clean "$(dirname "$source_path")" "$install_dir" || {
             log err "[INSTALL] Could not deploy to project directory."
             exit 1
         }

         # Symlinks in project only
         for name in "inmanage" "inm"; do
             local target="$install_dir/$name"
             local source="$install_dir/inmanage.sh"
             ln -sf "$source" "$target" || log err "[INSTALL] Failed to create symlink: $target"
         done

         log ok "[INSTALL] Project install completed in: $install_dir"
         log debug "[INSTALL] You can run './.inmanage/inmanage' or './.inmanage/inm' in this project."

         echo
         log info "Tip: You can install globally anytime via 'inmanage install --install-mode=1'"

         echo
         prompt_var "CREATE_CONFIG_NOW" "Would you like to create a project config now? [y/N]" "n"
         if [[ "${CREATE_CONFIG_NOW,,}" =~ ^(y|yes)$ ]]; then
             if command -v create_project_config &>/dev/null; then
                 create_project_config "$install_dir"
             else
                 log warn "[INSTALL] Function 'create_project_config' not found. Skipping config creation."
             fi
         fi

         return 0
     fi
      ;;
  esac

  echo
  prompt_var "CREATE_CONFIG" "Create project config now? [y/N]" "n"
  if [[ "$CREATE_CONFIG" =~ ^[YyJj]$ ]]; then
    create_own_config
  else
    log info "[SELF] Tip: Run 'inmanage create_config' to get started."
  fi
}
create_own_config() {
    log debug "[COC] init."
    INM_SELF_ENV_FILE="${NAMED_ARGS[target_file]:-${INM_SELF_ENV_FILE:-.inmanage/.env.inmanage}}"

    local target_dir
    target_dir="$(dirname "$INM_SELF_ENV_FILE")"
    mkdir -p "$target_dir" >/dev/null 2>&1 || {
        log err "[COC] Could not create directory '$target_dir'"
        exit 1
    }

    if [ -f "$INM_SELF_ENV_FILE" ] && [ "$force_update" != true ]; then
        log debug "[COC] Config file '$INM_SELF_ENV_FILE' already exists. Use create_config --force to recreate."
        return 0
    fi

    if [ -f "$INM_SELF_ENV_FILE" ]; then
        cp -f "$INM_SELF_ENV_FILE" "$INM_SELF_ENV_FILE.bak.$(date +%s)" >/dev/null 2>&1 || {
            log warn "[COC] Could not create backup of existing config."
        }
        rm -f "$INM_SELF_ENV_FILE" >/dev/null 2>&1 || {
            log err "[COC] Could not remove existing config file '$INM_SELF_ENV_FILE'. Aborting."
            exit 1
        }
    fi

    if ! touch "$INM_SELF_ENV_FILE"; then
        log err "[COC] Error: Could not write to '$INM_SELF_ENV_FILE'. Aborting."
        exit 1
    fi

    log info "[COC] Creating configuration in: $INM_SELF_ENV_FILE"
    echo -e "\n${GREEN}========== Install Wizard ==========${NC}\n"

    local non_interactive=true
    for key in "${prompt_order[@]}"; do
        if [ -z "${NAMED_ARGS[$key]+_}" ]; then
            non_interactive=false
            break
        fi
    done

    if [ "$non_interactive" = false ]; then
        log note "Just press [ENTER] to accept default values."
        for key in "${prompt_order[@]}"; do
            local defval="${default_settings[$key]}"
            local prompt_text="${prompt_texts[$key]:-"Provide value for $key:"}"
            read -r -p "$(echo -e "${GREEN}\n${prompt_text}\n${NC}${GRAY}[$defval]${NC}${RESET} > ")" input
            default_settings[$key]="${input:-$defval}"
        done
    else
        log info "[COC] All values provided via --key=value args. Skipping interactive prompt."
        for key in "${prompt_order[@]}"; do
            default_settings[$key]="${NAMED_ARGS[$key]:-${default_settings[$key]}}"
        done
    fi

    # Write prompted or passed values
    for key in "${prompt_order[@]}"; do
        echo "$key=\"${default_settings[$key]}\"" >> "$INM_SELF_ENV_FILE"
    done

    # Write other passed values not in prompt_order
    for key in "${!NAMED_ARGS[@]}"; do
        if [[ ! " ${prompt_order[*]} " =~  $key  ]]; then
            echo "$key=\"${NAMED_ARGS[$key]}\"" >> "$INM_SELF_ENV_FILE"
        fi
    done

    log ok "$INM_SELF_ENV_FILE has been created and configured."

    load_env_file_raw "$INM_SELF_ENV_FILE"

    if [ -z "$INM_BASE_DIRECTORY" ]; then
        log err "[COC] 'INM_BASE_DIRECTORY' is empty. Aborting."
        exit 1
    fi

    #todo : INM_ENV_EXAMPLE_FILE muss ein neues zuhause finden, wenn wir das script voll portabel machen. Bisher in .inmanage/ enthalten.
    # Wird in den lokalen cache geschrieben, wenn nicht vorhanden. 
    # todo sicherstellen dass das alles auch mit der self-installer funktioniert. 
    INM_ENV_EXAMPLE_FILE="${INM_BASE_DIRECTORY%/}/.inmanage/.env.example"
    log debug "[COC] INM_ENV_EXAMPLE_FILE set to $INM_ENV_EXAMPLE_FILE"

    log info "[COC] Downloading .env.example for provisioning"
    curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} \
        "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" \
        -o "$INM_ENV_EXAMPLE_FILE" || {
            log err "[COC] Failed to download .env.example"
            exit 1
        }

    if [ -f "$INM_ENV_EXAMPLE_FILE" ]; then
        sed -i '/^DB_PORT=/a DB_ELEVATED_USERNAME=\nDB_ELEVATED_PASSWORD=' "$INM_ENV_EXAMPLE_FILE"
    fi

    check_provision_file
}
enforce_ownership() {
    local paths=("$@")
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            if ! chown -R "$ENFORCED_USER:$ENFORCED_USER" "$path" 2>/dev/null; then
                log warn "[EU] chown failed for $path"
            fi
        fi
    done
}
get_installed_version() {

    # USAGE:
    # if installed_version=$(get_installed_version); then
    #     log debug "[UPD] Installed version is $installed_version"
    # else
    #     case $? in
    #         1) log info "[UPD] No installed version detected. Proceeding as fresh install." ;;
    #         2) log err "[UPD] Could not read installed version. Manual check required."; exit 1 ;;
    #     esac
    # fi

    log debug "[GIV] Retrieving installed version from VERSION.txt"
    local version_file="$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/VERSION.txt"

    if [ -f "$version_file" ]; then
        local version
        version=$(<"$version_file") || {
            log err "[GIV] Failed to read installed version from $version_file"
            return 2
        }
        log debug "[GIV] Installed version: $version"
        echo "$version"
        return 0
    else
        log info "[GIV] No VERSION.txt found – assuming fresh install"
        return 1
    fi
}
get_latest_version() {
    ##########
    # USAGE:
    # if latest_version=$(get_latest_version); then
    # ########       
    #    if latest_version=$(get_latest_version); then
    #        log debug "Comparing installed vs. latest version: $installed_version → $latest_version"
    #    else
    #        log warn "Could not determine latest version – skipping update."
    #        return
    #    fi

    log debug "[GLV] Retrieving latest version from GitHub API"

    local version
    version=$(curl -sS \
        --connect-timeout 5 \
        --max-time 15 \
        --retry 3 \
        --retry-delay 2 \
        --retry-all-errors \
        ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} \
        https://api.github.com/repos/invoiceninja/invoiceninja/releases/latest \
        | jq -r '.tag_name' | sed 's/^v//')

    if [[ -z "$version" || "$version" == "null" ]]; then
        log info "Consider adding GitHub API credentials to your .env file to avoid rate limits."
        log err "[GLV] No valid version tag found in GitHub API response"
        return 1
    fi

    log debug "[GLV] Latest GitHub version: $version"
    echo "$version"
    return 0
}
safe_move_or_copy_and_clean() {
    # safe_move_or_copy_and_clean(): Safely move or copy a file or directory from SRC to DST.
    # With fallback using rsync or cp -a, and optional cleanup of source.
    # Supports "new" (DST must not exist) and "existing" (DST must exist) modes.
    # Parameters:
    #   $1 = src (source path)
    #   $2 = dst (destination path)
    #   $3 = mode (optional: "new" or "existing")
    #   $4 = rsync_opts (optional: extra rsync options as string)

    local src="$1"
    local dst="$2"
    local mode="$3"
    local rsync_opts_str="$4"
    local -a rsync_opts

    # Parse optional rsync options string into array
    if [[ -n "$rsync_opts_str" ]]; then
        read -r -a rsync_opts <<< "$rsync_opts_str"
    fi

    if [ ! -e "$src" ]; then
        log err "[SM] Source '$src' does not exist."
        return 1
    fi

    local is_dir="false"
    [ -d "$src" ] && is_dir="true"

    # Canonicalize paths if possible
    local src_real dst_real
    if command -v realpath >/dev/null 2>&1; then
        src_real="$(realpath "$src")"
        dst_real="$(realpath "$dst" 2>/dev/null || echo "$dst")"
        if [ "$src_real" = "$dst_real" ]; then
            log err "[SM] Source and destination are the same ('$src_real') – aborting to avoid data loss."
            return 1
        fi
    else
        log debug "[SM] 'realpath' not found – skipping identity check between src and dst"
    fi

    # Mode detection
    if [ -z "$mode" ]; then
        if [ -e "$dst" ]; then
            mode="existing"
        else
            mode="new"
        fi
    fi

    log debug "[SM] Operation mode: $mode"
    log debug "[SM] Source type: $([[ "$is_dir" == "true" ]] && echo dir || echo file)"
    log debug "[SM] Attempting mv '$src' → '$dst'"

    if [ "$is_dir" = "false" ] || { [ "$mode" = "new" ] && [ ! -e "$dst" ]; }; then
        if mv "$src" "$dst" 2>/dev/null; then
            log debug "[SM] mv succeeded: '$src' → '$dst'"
            return 0
        else
            log debug "[SM] mv failed. Falling back to copy+clean method."
        fi
    fi

    # Prepare destination
    if [ "$mode" = "new" ]; then
        if [ "$is_dir" = "true" ]; then
            mkdir -p "$dst" || {
                log err "[SM] Failed to create target directory '$dst'"
                return 1
            }
        else
            mkdir -p "$(dirname "$dst")" || {
                log err "[SM] Failed to create parent directory for '$dst'"
                return 1
            }
        fi
    elif [ "$mode" = "existing" ] && [ ! -e "$dst" ]; then
        log err "[SM] Expected existing target '$dst', but it does not exist"
        return 1
    fi

    # Fallback copy
    if command -v rsync >/dev/null; then
        log debug "[SM] Using rsync for fallback copy"
        if [ "$is_dir" = "true" ]; then
            rsync -a --delete "${rsync_opts[@]}" "$src"/ "$dst"/ || {
                log err "[SM] rsync fallback (directory) failed."
                return 1
            }
        else
            rsync -a "${rsync_opts[@]}" "$src" "$dst" || {
                log err "[SM] rsync fallback (file) failed."
                return 1
            }
        fi
    else
        log debug "[SM] rsync not found. Using cp fallback"
        if [ "$is_dir" = "true" ]; then
            cp -a "$src"/. "$dst"/ || {
                log err "[SM] cp fallback (directory) failed."
                return 1
            }
        else
            cp -a "$src" "$dst" || {
                log err "[SM] cp fallback (file) failed."
                return 1
            }
        fi
    fi

    # Sanity check (dir only)
    if [ "$is_dir" = "true" ] && [ -z "$(find "$dst" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        log warn "[SM] Target directory appears empty after copy. Proceed anyway? (yes/no): "
        [[ "$DEBUG" == "true" ]] && log debug "Prompting user: Empty target dir after copy"
        if ! read -r -t 60 response; then
            log warn "[SM] No response within 60 seconds. Operation aborted."
            return 1
        fi
        if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            log info "[SM] Operation aborted by user."
            return 1
        fi
    fi

    # Cleanup source
    log debug "[SM] Cleaning source '$src'"
    if command -v rsync >/dev/null; then
        if [ "$is_dir" = "true" ]; then
            local tmp_empty="/tmp/.inm_emptydir"
            mkdir -p "$tmp_empty"
            rsync -a --delete "$tmp_empty"/ "$src"/ || {
                log err "[SM] Failed to clean source directory via rsync."
                return 1
            }
        else
            rm -f "$src" || {
                log err "[SM] Failed to delete source file '$src'"
                return 1
            }
        fi
    else
        if [ "$is_dir" = "true" ]; then
            find "$src" -mindepth 1 -exec rm -rf {} + 2> >(while read -r line; do
                [[ "$DEBUG" == "true" ]] && log debug "$line"
            done) || {
                log err "[SM] Failed to clean source directory."
                return 1
            }
        else
            rm -f "$src" || {
                log err "[SM] Failed to delete source file '$src'"
                return 1
            }
        fi
    fi

    log ok "[SM] Fallback copy+clean completed."
    return 0
}
do_snappdf() {

    load_env_file_raw "$INM_ENV_FILE" || {
    log err "[PDF] Failed to load DB variables from $INM_ENV_FILE"
    exit 1
    }


    if [ -z "$PDF_GENERATOR" ]; then
        log err "[PDF] PDF_GENERATOR is not set in .env file. Please set it to 'snappdf' / 'phantom' or 'hosted_ninja'."
        exit 1
    fi

    if [ "$PDF_GENERATOR" = "snappdf" ]; then
        log info "[PDF] Snappdf configuration detected."

        if [ -n "$SNAPPDF_CHROMIUM_PATH" ]; then
            log info "[PDF] Chromium path is set to '$SNAPPDF_CHROMIUM_PATH'. Skipping ungoogled chrome download via SNAPPDF_SKIP_DOWNLOAD."
            export SNAPPDF_SKIP_DOWNLOAD=true
        fi

        local path="${INM_BASE_DIRECTORY%/}${INM_INSTALLATION_DIRECTORY#/}"
        cd "$path" || {
            log err "[PDF] Failed to change directory to $path"
            return 1
        }

        if [ ! -f "./vendor/bin/snappdf" ]; then
            log err "[PDF] Snappdf binary './vendor/bin/snappdf' not found."
            return 1
        fi

        if [ ! -x "./vendor/bin/snappdf" ]; then
            log debug "[PDF] The file ./vendor/bin/snappdf is not executable. Adding executable flag."
            chmod +x ./vendor/bin/snappdf
        fi

        log debug "[PDF] Download and install Chromium if needed."
        $INM_PHP_EXECUTABLE ./vendor/bin/snappdf download

    else
        log info "[PDF] PDF generation is set to '$PDF_GENERATOR'"
    fi
}
install_cronjob() {
    # ---------------------------------------------------------------------
    # install_cronjob()
    #
    # Installs one or more recurring preconfigured cron jobs for Invoice Ninja, either via:
    # - /etc/cron.d/ (requires root, system-wide, asks for root password via prompt_var)
    # - crontab -e (user-specific fallback if --mode=crontab is selected)
    #
    # Supports:
    # - Systemd and non-systemd environments
    # - Cron availability checks
    # - Enforced execution as prompted user
    #
    # Parameters:
    #   --force         Overwrite existing cron jobs
    #   --jobs=[type]   Which jobs to install: artisan, backup, all (default: artisan)
    #   --mode=[type]   Installation mode: cron.d (default), crontab
    #   --name=[suffix] Suffix for cron job file name (e.g. invoiceninja_custom)
    #
    # Example:
    #   install_cronjob --jobs=all --mode=crontab --force --name=production
    # ---------------------------------------------------------------------

    local force=false
    local job_type="artisan"
    local mode="cron.d"
    local cron_name="invoiceninja"

    declare -A ARGS
    parse_named_args ARGS "$@"

    force="${ARGS[force]:-false}"
    job_type="${ARGS[jobs]:-artisan}"
    mode="${ARGS[mode]:-cron.d}"
    cron_name="invoiceninja_${ARGS[name]:-default}"

    log debug "[CRON] Installing cronjob with parameters: force=$force, job_type=$job_type, mode=$mode, name=$cron_name"

    # Check if cron service is running
    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running --quiet 2>/dev/null; then
        if ! systemctl is-active --quiet cron; then
            log err "[CRON] 'cron' service is not active (systemd detected)"
            return 1
        fi
    elif ! pgrep -x cron >/dev/null 2>&1; then
        log err "[CRON] Cron daemon is not running on this system"
        return 1
    fi

    # Verify enforced user exists
    if ! id "$INM_ENFORCED_USER" >/dev/null 2>&1; then
        log err "[CRON] Enforced user '$INM_ENFORCED_USER' does not exist"
        return 1
    fi

    # Prepare cron lines
    local artisan_job="* * * * * $INM_ENFORCED_USER $INM_ARTISAN schedule:run >> /dev/null 2>&1"
    local backup_job="0 3 * * * $INM_ENFORCED_USER $INM_ENFORCED_SHELL -c \"$INM_BASE_DIRECTORY/inmanage.sh backup\" >> /dev/null 2>&1"

    if [ "$mode" = "cron.d" ]; then
        local cronfile="/etc/cron.d/$cron_name"

        if [ -f "$cronfile" ] && [ "$force" != true ]; then
            log warn "[CRON] Cronjob already exists: $cronfile"
            log info "[CRON] Use --force to overwrite or choose a different --name"
            return 0
        fi

        if [ ! -d /etc/cron.d ]; then
            log err "[CRON] /etc/cron.d not available – system not compatible with cron.d style"
            return 1
        fi

        local root_user=""
        local root_pass=""
        local attempts=0

        until [ "$attempts" -ge 3 ]; do
            root_user=$(prompt_var "root_user" "root" "Enter user to install cronjob as (default: root)" false 30)
            root_pass=$(prompt_var "root_pass" "" "Enter password for user '$root_user'" true 30)

            if echo "$root_pass" | sudo -S -u "$root_user" true 2>/dev/null; then
                break
            else
                log warn "[CRON] Authentication failed. Attempt $((++attempts))/3."
            fi
        done

        if [ "$attempts" -ge 3 ]; then
            log err "[CRON] Authentication failed 3 times. Aborting."
            return 1
        fi

        {
            echo "# Invoice Ninja Cronjobs – installed by inmanage"
            if [[ "$job_type" == "artisan" || "$job_type" == "all" ]]; then
                echo "$artisan_job"
            fi
            if [[ "$job_type" == "backup" || "$job_type" == "all" ]]; then
                echo "$backup_job"
            fi
        } | sudo -S -u "$root_user" tee "$cronfile" >/dev/null

        sudo -S -u "$root_user" chmod 644 "$cronfile"
        sudo -S -u "$root_user" chown root:root "$cronfile"

        log ok "[CRON] Installed cronjob to: $cronfile"

    elif [ "$mode" = "crontab" ]; then
        if ! command -v crontab >/dev/null 2>&1; then
            log err "[CRON] 'crontab' command is missing – cannot install to user crontab"
            return 1
        fi

        local temp_cron temp_clean temp_new
        temp_cron=$(mktemp)
        temp_clean=$(mktemp)
        temp_new=$(mktemp)

        crontab -u "$INM_ENFORCED_USER" -l 2>/dev/null > "$temp_cron" || true

        grep -v "inmanage.sh backup" "$temp_cron" | grep -v "$INM_ARTISAN schedule:run" > "$temp_clean"

        {
            cat "$temp_clean"
            echo "# Invoice Ninja Cronjobs – installed by inmanage"
            if [[ "$job_type" == "artisan" || "$job_type" == "all" ]]; then
                echo "$artisan_job"
            fi
            if [[ "$job_type" == "backup" || "$job_type" == "all" ]]; then
                echo "$backup_job"
            fi
        } > "$temp_new"

        crontab -u "$INM_ENFORCED_USER" "$temp_new" && \
        log ok "[CRON] Cronjob(s) added to crontab for user: $INM_ENFORCED_USER"

        rm -f "$temp_cron" "$temp_clean" "$temp_new"

    else
        log err "[CRON] Invalid mode: '$mode' – use 'cron.d' or 'crontab'"
        return 1
    fi
}
download_ninja() {
    # ---------------------------------------------------------------------
    # download_ninja()
    #
    # Downloads the specified Invoice Ninja version as a .tar.gz file.
    # The function checks if the version is already cached in the global or
    # local cache. If not, it will download the .tar.gz file and store it
    # in the appropriate cache directory.
    #
    # GitHub authentication is handled via INM_GH_API_CREDENTIALS if provided.
    #
    # Parameters:
    #   $1    version     The Invoice Ninja version to download (e.g., "5.2.0").
    #
    # Globals:
    #   INM_GH_API_CREDENTIALS  GitHub API credentials for authentication (if needed).
    #   INM_CACHE_LOCAL_DIRECTORY  Local cache directory.
    #   INM_CACHE_GLOBAL_DIRECTORY Global cache directory.
    #
    # Example usage:
    #   download_ninja "5.2.0"
    # ---------------------------------------------------------------------

    local version="$1"
    local cache_dir
    local target_file
    local temp_file

    temp_file=$(mktemp)
    cache_dir=$(resolve_cache_directory)
    target_file="$cache_dir/invoiceninja_v$version.tar.gz"
    local force="${NAMED_ARGS[force]:-false}"
    local debug_keep_tmp="${NAMED_ARGS[debug_keep_tmp]:-false}"

    # todo: force parameter should be used to force download even if file exists.
    if [ -f "$target_file" ]; then
        log debug "[DN] Using cached version for $version at $target_file"
        return 0
    fi

    log info "[DN] Downloading Invoice Ninja $version..."

    if [ -n "$INM_GH_API_CREDENTIALS" ]; then
    log debug "[DN] Using GitHub API credentials for download."
        if [[ "$INM_GH_API_CREDENTIALS" =~ ^token: ]]; then
            CURL_AUTH_FLAG="-H 'Authorization: token ${INM_GH_API_CREDENTIALS#token:}'"
        elif [[ "$INM_GH_API_CREDENTIALS" =~ ^[^:]*: ]]; then
            USERNAME_PASSWORD="${INM_GH_API_CREDENTIALS//:/ }"
            CURL_AUTH_FLAG="-u ${USERNAME_PASSWORD}"
        else
            log warn "[DN] Invalid INM_GH_API_CREDENTIALS format, skipping authentication"
            CURL_AUTH_FLAG=""
        fi
    fi

    local download_url="https://github.com/invoiceninja/invoiceninja/releases/download/v$version/invoiceninja.tar.gz"

    if curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} -w "%{http_code}" "$download_url" -o "$temp_file" | grep -q "200"; then
        if [ $(wc -c < "$temp_file") -gt 1048576 ]; then
            mv "$temp_file" "$target_file"
            log ok "[DN] Download successful."
        else
            log err "[DN] Download failed: File is too small. Please check network."
            rm "$temp_file"
            exit 1
        fi
    else
        log err "[DN] Download failed: HTTP-Statuscode not 200. Please check network. Maybe you need GitHub credentials."
        rm "$temp_file"
        exit 1
    fi

    log ok "[DN] Invoice Ninja $version downloaded and cached at $target_file"
}
cleanup_cache() {
    log info "[CC] Cleaning up old cached Invoice Ninja versions..."

    local cache_dir
    cache_dir=$(resolve_cache_directory) 

    if [ ! -d "$cache_dir" ]; then
        log warn "[CC] Cache directory $cache_dir does not exist. Skipping cleanup."
    fi

    find "$cache_dir" -maxdepth 1 -type f -name 'invoiceninja_*.tar.gz' \
        | sort -rV \
        | tail -n +$((INM_CACHE_GLOBAL_RETENTION + 1)) \
        | while read -r file; do
            log debug "[CC] Removing: $file"
            rm -f "$file"
        done

    log ok "[CC] Cleanup of cached versions completed. Keeping the last $INM_CACHE_GLOBAL_RETENTION versions."
}
run_installation() {
    
    # ---------------------------------------------------------------------
    # install
    #
    # Installs a clean, unprovisioned Invoice Ninja instance from a cached release archive.
    # The resulting installation includes core files, a fresh .env,
    # and all base artisan tasks. Final setup must be completed via the web interface.
    #
    # Behavior:
    # - Downloads and extracts the latest release from cache (if not already done)
    # - Archives any existing installation directory (with confirmation or force override)
    # - Copies fresh files into a temp directory, then moves them into place
    # - Applies the provided .env file if available (or warns if missing)
    # - Runs essential artisan commands:
    #     - key:generate
    #     - optimize
    #     - up
    #     - ninja:translations
    # - Does not run database migrations or create an admin user
    #
    # Note:
    #   After execution, open your browser and complete the setup manually via the web interface.
    #
    # Globals:
    #   INM_BASE_DIRECTORY, INM_INSTALLATION_DIRECTORY, INM_PROVISION_ENV_FILE,
    #   INM_ARTISAN_STRING, force_update
    # ---------------------------------------------------------------------

    local mode="$1"
    local env_file timestamp latest_version response source_dir
    timestamp="$(date +'%Y%m%d_%H%M%S')"
    latest_version="$(get_latest_version)"

    if [ "$mode" = "Provisioned" ]; then
        env_file="${INM_BASE_DIRECTORY%/}/${INM_PROVISION_ENV_FILE#/}"
    else
        env_file="${INM_INSTALLATION_DIRECTORY}_temp/.env.example"
    fi

    # Check for existing installation
    if [ -d "${INM_BASE_DIRECTORY%/}/${INM_INSTALLATION_DIRECTORY#/}" ]; then
        local src_path="${INM_BASE_DIRECTORY%/}/${INM_INSTALLATION_DIRECTORY#/}"
        local dst_path="${INM_BASE_DIRECTORY%/}/_last_IN_${timestamp}"

        if [ "$force_update" != true ]; then
            log warn "[TAR] Installation directory already exists – archive current version?"
            log info "[TAR] Proceed with installation and archive the current directory? (yes/no):"
            if ! read -r -t 60 response; then
                log warn "[TAR] No response within 60 seconds. Installation aborted."
                return 0
            fi
            if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                log info "[TAR] Installation aborted by user."
                return 0
            fi
        else
            log info "[TAR] Forced install – archiving current version"
        fi

        safe_move_or_copy_and_clean "$src_path" "$dst_path" new || {
            log err "[TAR] Failed to archive old installation"
            return 1
        }
    fi

    log info "[TAR] Installation begins"

    source_dir="$(download_ninja "$latest_version")" || {
        log err "[TAR] Download failed"
        return 1
    }

    mkdir -p "${INM_INSTALLATION_DIRECTORY}_temp" || {
        log err "[TAR] Failed to create temp directory"
        return 1
    }
    #todo: umstellen auf neuen cache
    log info "[TAR] Copying clean installation from cache: $source_dir"
    cp -a "$source_dir/." "${INM_INSTALLATION_DIRECTORY}_temp/" || {
        log err "[TAR] Failed to copy files from cache"
        return 1
    }

    # Restore .env*.inmanage files from archive into new temp install -if any.
    local archived_dir="${INM_BASE_DIRECTORY%/}/_last_IN_${timestamp}"
    local target_dir="${INM_INSTALLATION_DIRECTORY}_temp"

    log debug "[TAR] Checking for .env*.inmanage files in: $archived_dir"

    shopt -s nullglob
    local restore_candidates=("$archived_dir"/.env*.inmanage)
    if [ ${#restore_candidates[@]} -gt 0 ]; then
        for file in "${restore_candidates[@]}"; do
            cp -f "$file" "$target_dir/" 2>/dev/null && \
                log debug "[TAR] Restored $(basename "$file") to $target_dir"
        done
    else
        log debug "[TAR] No .env*.inmanage files found for restore"
    fi
    shopt -u nullglob


    # Place .env if available
    if [ -f "$env_file" ]; then
        cp "$env_file" "${INM_INSTALLATION_DIRECTORY}_temp/.env" || {
            log err "[TAR] Failed to place .env"
            return 1
        }
        chmod 600 "${INM_INSTALLATION_DIRECTORY}_temp/.env" || \
            log warn "[TAR] chmod 600 failed on .env"
    else
        log warn "[TAR] No .env found – installation will not be functional without manual setup"
        if [ "$force_update" = true ]; then
            log info "[TAR] Force mode enabled – proceeding anyway"
        else
            log warn "[TAR] Abort or continue? Type 'yes' to proceed:"
            read -r confirm
            [[ "$confirm" != "yes" ]] && {
                log info "[TAR] Installation cancelled by user"
                return 1
            }
        fi
    fi

    safe_move_or_copy_and_clean "${INM_INSTALLATION_DIRECTORY}_temp" "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" || {
        log err "[TAR] Failed to deploy new installation"
        return 1
    }

    # Check existence and fix if necessary
    if [ ! -x "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/artisan" ]; then
        chmod +x "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/artisan" || {
            log err "[TAR] Cannot fix artisan permissions"
            return 1
        }
    fi

    log info "[TAR] Running post-installation artisan tasks"

    "$INM_ARTISAN_STRING" key:generate --force || log warn "[TAR] artisan key:generate failed"
    "$INM_ARTISAN_STRING" optimize || log warn "[TAR] artisan optimize failed"
    "$INM_ARTISAN_STRING" up || log warn "[TAR] artisan up failed"
    "$INM_ARTISAN_STRING" ninja:translations || log warn "[TAR] artisan translations failed"
    do_snappdf || log warn "[TAR] Snappdf setup failed"

     #shellcheck disable=SC2059
     #shellcheck disable=SC2015
    if [ "$mode" = "Provisioned" ]; then
        "$INM_ARTISAN_STRING" migrate:fresh --seed --force || {
            log err "[TAR] Failed to migrate and seed"
            return 1
        }
        "$INM_ARTISAN_STRING" ninja:create-account --email=admin@admin.com --password=admin && {
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
            printf "  ${CYAN}* * * * * $INM_ENFORCED_USER $INM_ARTISAN_STRING schedule:run >> /dev/null 2>&1${RESET}\n"
            printf "  ${CYAN}* 3 * * * $INM_ENFORCED_USER $INM_ENFORCED_SHELL -c \"$INM_BASE_DIRECTORY./inmanage.sh backup\" >> /dev/null 2>&1${RESET}\n\n"
            printf "${BOLD}To install cronjobs automatically, use:${RESET}\n"
            printf "  ${CYAN}./inmanage.sh install_cronjob user=$INM_ENFORCED_USER jobs=both${RESET}\n"
            printf "  Full explanation available via ${CYAN}./inmanage.sh -h${RESET}\n\n"
        } || {
            log err "[TAR] Failed to create default user"
            return 1
        }
        todo: alle inmanage.sh umstellen auf $SCRIPT_NAME GERNE AUCH $SCRIPT_PATH
    else       
        printf "\n${BLUE}%s${RESET}\n" "========================================"
        printf "${GREEN}${BOLD}Setup Complete!${RESET}\n\n"
        printf "${WHITE}Open your browser at your configured address ${CYAN}https://your.url/setup${RESET} to complete database setup.${RESET}\n\n"
        printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
        printf "${BOLD}To install cronjobs automatically, use:${RESET}\n"
        printf "  ${CYAN}./inmanage.sh install_cronjob user=$INM_ENFORCED_USER${RESET}\n"
        printf "  Full explanation available via ${CYAN}./inmanage.sh -h${RESET}\n\n"
    fi

    cd "$INM_BASE_DIRECTORY"
    return 0
}
run_update() {

    # ---------------------------------------------------------------------
    # run_update()
    #
    # Updates Invoice Ninja to the latest available or specified version.
    #
    # Behavior:
    # - Checks current installed version via VERSION.txt
    # - Compares against latest release (or specified via --version)
    # - Downloads and verifies release archive
    # - Extracts to temp directory and runs artisan upgrade
    # - Performs atomic switch to new version directory
    # - Restarts PHP-FPM if required
    #
    # Parameters:
    #   --version=<x.y.z>      Target version (default: latest)
    #   --force                Force update even if version is current
    #
    # Globals:
    #   INM_INSTALL_PATH, INM_PHP_VERSION, INM_WEBUSER, INM_DOWNLOAD_CACHE, INM_FORCE_RESTART
    #
    # Example:
    #   run_update --version=5.9.2 --force
    # ---------------------------------------------------------------------


    local -A args=()
    parse_named_args args "$@"

    local installed_version latest_version timestamp response source_dir
    timestamp="$(date +'%Y%m%d_%H%M%S')"

    installed_version=$(get_installed_version)
    latest_version="${args[version]:-$(get_latest_version)}"


    if [ ! -f "$INM_ENV_FILE" ]; then
    log warn "[UPD] No .env file found – the system is not provisioned or broken."
    log debug "[UPD] Please check the .env file location at $INM_ENV_FILE"
    log info "[UPD] Use 'spawn_provision' to set up a new system fast, use '-h' to see more options, or move a valid .env file into '$INM_INSTALLATION_DIRECTORY' to fix a potentially broken installation."
    return 1
    fi

    if version_compare "$installed_version" gt "$latest_version"; then
        log warn "[UPD] You are attempting a downgrade: $installed_version → $latest_version"
        if [ "$force_update" != true ]; then
            log warn "[UPD] Proceed? Type 'yes' to continue:"
            read -r confirm
            [[ "$confirm" != "yes" ]] && {
                log info "[UPD] Downgrade aborted."
                return 1
            }
        else
            log info "[UPD] Force flag set. Proceeding with downgrade."
        fi
    elif [[ "$installed_version" == "$latest_version" && "$force_update" != true ]]; then
        log info "[UPD] Version $installed_version is already current. Proceed anyway? (yes/no):"
        read -r -t 60 response || {
            log warn "[UPD] No response. Update aborted."
            return 0
        }
        [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]] && {
            log info "[UPD] Update cancelled by user."
            return 0
        }
    fi

    source_dir="$(download_ninja "$latest_version")" || {
        log err "[UPD] Failed to download or locate target version."
        return 1
    }

    # Halt system.
    if [ -x "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/artisan" ]; then
    "$INM_ARTISAN_STRING" cache:clear || log warn "[UPD] artisan cache:clear failed"
    "$INM_ARTISAN_STRING" down || log warn "[UPD] Maintenance mode activation failed"
    fi

    # Backup old installation
    log info "[UPD] Archiving current installation"
    safe_move_or_copy_and_clean "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$timestamp" new || {
        log err "[UPD] Backup of old installation failed"
        return 1
    }

    # Deploy from cache to live installation
    log info "[UPD] Copying version $latest_version to live installation"
    cp -a "$source_dir/." "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/" 2>/dev/null || {
        log err "[UPD] Copy to live directory failed"
        return 1
    }

    # Restore config and runtime files
    log info "[UPD] Restoring .env and persistent files"

    cp "$INM_ENV_FILE" "$INM_INSTALLATION_DIRECTORY/" 2>/dev/null || log warn "[UPD] Failed to restore .env"
    chmod 600 "$INM_INSTALLATION_DIRECTORY/.env" 2>/dev/null || log warn "[UPD] chmod on .env failed"

    # Restore .inmanage and .env.*.inmanage files if present
    for f in "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$timestamp"/.env*.inmanage \
            "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$timestamp"/.inmanage*.inmanage; do
        [ -f "$f" ] || continue
        cp -f "$f" "$INM_BASE_DIRECTORY" 2>/dev/null || log warn "[UPD] Failed to restore $f"
        chmod 644 "$INM_BASE_DIRECTORY/$(basename "$f")" 2>/dev/null || true
    done

    # Restore storage directory using rsync
    rsync -a \
    "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$timestamp/public/storage/" \
    "$INM_INSTALLATION_DIRECTORY/public/storage/" 2>/dev/null || log note "[UPD] rsync failed to restore storage/"

    # Restore public/*.ini files
    cp -f "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$timestamp/public/"*.ini \
        "$INM_INSTALLATION_DIRECTORY/public/" 2>/dev/null || true

    # Restore .htaccess
    cp -f "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$timestamp/public/.htaccess" \
        "$INM_INSTALLATION_DIRECTORY/public/" 2>/dev/null || true

    # Collect files for ownership enforcement
    ini_files=()
    for f in "$INM_INSTALLATION_DIRECTORY/public/"*.ini "$INM_INSTALLATION_DIRECTORY/public/".*.ini \
        "$INM_INSTALLATION_DIRECTORY/.env.inmanage" "$INM_INSTALLATION_DIRECTORY/.env."*.inmanage; do
        [ -e "$f" ] && ini_files+=("$f")
    done

    # Enforce ownership on critical files
    [ -n "$ENFORCED_USER" ] && enforce_ownership \
        "$INM_INSTALLATION_DIRECTORY/.env" \
        "$INM_INSTALLATION_DIRECTORY/public/storage" \
        "$INM_INSTALLATION_DIRECTORY/public/.htaccess" \
        "${ini_files[@]}"

    # Verify artisan is usable in the new installation
    if [ ! -x "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/artisan" ]; then
        log err "[UPD] Artisan not found or not executable in new version"
        return 1
    fi

    # Run update tasks in the new live system
    log info "[UPD] Running post-update artisan tasks"
    "$INM_ARTISAN_STRING" optimize || log warn "[UPD] artisan optimize failed"
    "$INM_ARTISAN_STRING" migrate --force || log warn "[UPD] artisan migrate failed"
    "$INM_ARTISAN_STRING" ninja:post-update || log warn "[UPD] artisan post-update failed"
    "$INM_ARTISAN_STRING" ninja:check-data || log warn "[UPD] artisan check-data failed"
    "$INM_ARTISAN_STRING" ninja:translations || log warn "[UPD] artisan translations failed"
    "$INM_ARTISAN_STRING" ninja:design-update || log warn "[UPD] artisan design-update failed"
    "$INM_ARTISAN_STRING" up || log warn "[UPD] artisan up failed"

    do_snappdf || log warn "[UPD] Snappdf setup failed"
    cleanup || log warn "[UPD] Cache cleanup failed"
    log ok "[UPD] Update completed successfully!"
}
run_backup() {

    # ---------------------------------------------------------------------
    # run_backup()
    # 
    # Creates a backup of Invoice Ninja, including:
    # - Database (MySQL/MariaDB)
    # - Application storage and uploads (storage/*, public/logo, public/uploads)
    # - Optional: compression format (tar.gz, zip, or none)
    #
    # Supports:
    # - Selective backup (--db, --storage, --uploads, or full --fullbackup)
    # - Optional bundling (--bundle) of all parts into one archive
    # - Named output (--name) for identifying backup sets
    # - Compression selection (--compress=tar.gz|zip|false)
    #
    # Parameters:
    #   --fullbackup        Default true, includes everything unless overridden
    #   --db                Backup database only (overrides --fullbackup)
    #   --storage           Include 'storage/' folder
    #   --uploads           Include 'public/uploads' and 'public/logo'
    #   --compress=[type]   Compression format: tar.gz (default), zip, false
    #   --bundle=[true|false]  Bundle all parts into a single archive (default: true)
    #   --name=[suffix]     Custom name suffix (appended to archive name)
    #
    # Env/Config flags:
    #   INM_FORCE_READ_DB_PW  If 'Y', forces usage of .env password for DB dump
    #   INM_DUMP_OPTIONS      mysqldump options (e.g., --quick, --no-tablespaces)
    #
    # ---------------------------------------------------------------------

    declare -A ARGS
    parse_named_args ARGS "$@"

    local compress="${ARGS[compress]:-tar.gz}"
    local bundle="${ARGS[bundle]:-true}"
    local name="${ARGS[name]:-$(date +%Y%m%d-%H%M)}"

    local db="${ARGS[db]:-false}"
    local storage="${ARGS[storage]:-false}"
    local uploads="${ARGS[uploads]:-false}"
    local fullbackup="${ARGS[fullbackup]:-true}"

    # fullbackup true → alle auf true
    if [[ "$fullbackup" == "true" ]]; then
        db=true
        storage=true
        uploads=true
    else
        # if fullbackup false → all false
        [[ "$db" == "true" || "$storage" == "true" || "$uploads" == "true" ]] && fullbackup=false
    fi

    local ts
    ts="$(date +%Y-%m-%d_%H-%M)"
    local base_name="${INM_PROGRAM_NAME:-invoiceninja}_${name}_${ts}"

    local db_file="$INM_BACKUP_DIRECTORY/${base_name}_db.sql"
    local storage_file="$INM_BACKUP_DIRECTORY/${base_name}_storage.tar.gz"
    local uploads_file="$INM_BACKUP_DIRECTORY/${base_name}_uploads.tar.gz"
    local bundle_file="$INM_BACKUP_DIRECTORY/${base_name}_full"

    [[ "$compress" == "zip" ]] && bundle_file+=".zip"
    [[ "$compress" == "tar.gz" ]] && bundle_file+=".tar.gz"
    [[ "$compress" == "false" ]] && bundle_file+=".bak"

    mkdir -p "$INM_BACKUP_DIRECTORY"

    # === DATABASE DUMP ===
    if [[ "$db" == "true" ]]; then
        log info "[BACKUP] Dumping database..."

        local dump_cmd=("mysqldump")
        if [[ -n "$INM_DUMP_OPTIONS" ]]; then
         read -r -a tmp_opts <<< "$INM_DUMP_OPTIONS"
         dump_cmd+=("${tmp_opts[@]}")
        fi

        dump_cmd+=("-u$DB_USERNAME" "-h$DB_HOST" "$DB_DATABASE")

        if [[ "$INM_FORCE_READ_DB_PW" == "Y" ]]; then
            log debug "[BACKUP] INM_FORCE_READ_DB_PW=Y → Using .env password"
            dump_cmd+=("-p$DB_PASSWORD")
            if ! "${dump_cmd[@]}" > "$db_file"; then
                log err "[BACKUP] Database dump failed using .env password"
                return 1
            fi
        else
            log debug "[BACKUP] INM_FORCE_READ_DB_PW≠Y → Attempt .my.cnf"
            if ! "${dump_cmd[@]}" > "$db_file" 2>_dump.err; then
                if grep -qi "Access denied" _dump.err; then
                    log warn "[BACKUP] .my.cnf failed – prompt for password"
                    local success=false
                    for attempt in {1..3}; do
                        DB_PASSWORD=$(prompt_var DB_PASSWORD "" \
                            "Enter database password (user: $DB_USERNAME)" true 60) || {
                            log err "[BACKUP] No password entered – aborting"
                            break
                        }
                        dump_cmd=("${dump_cmd[@]/-u$DB_USERNAME/-u$DB_USERNAME -p$DB_PASSWORD}")
                        if "${dump_cmd[@]}" > "$db_file"; then
                            success=true
                            break
                        else
                            log warn "[BACKUP] Dump failed (attempt $attempt)"
                        fi
                    done
                    rm -f _dump.err
                    [[ "$success" != true ]] && return 1
                else
                    cat _dump.err >&2
                    rm -f _dump.err
                    return 1
                fi
            else
                rm -f _dump.err
            fi
        fi

        log ok "[BACKUP] Database dumped: $db_file"
    fi

    # === STORAGE ===
    if [[ "$storage" == "true" ]]; then
        log info "[BACKUP] Archiving storage/"
        tar -czf "$storage_file" -C "$INM_BASE_DIRECTORY" storage
        log ok "[BACKUP] Storage archived: $storage_file"
    fi

    # === UPLOADS ===
    if [[ "$uploads" == "true" ]]; then
        log info "[BACKUP] Archiving uploads/"
        tar -czf "$uploads_file" -C "$INM_BASE_DIRECTORY/public" uploads logo 2>/dev/null
        log ok "[BACKUP] Uploads archived: $uploads_file"
    fi

    # === BUNDLE ===
    if [[ "$bundle" == "true" ]]; then
        log info "[BACKUP] Creating bundle: $bundle_file"
        local bundle_parts=()
        [[ -f "$db_file" ]] && bundle_parts+=("$db_file")
        [[ -f "$storage_file" ]] && bundle_parts+=("$storage_file")
        [[ -f "$uploads_file" ]] && bundle_parts+=("$uploads_file")

        if [[ "$compress" == "zip" ]]; then
            zip -j "$bundle_file" "${bundle_parts[@]}" >/dev/null
        elif [[ "$compress" == "tar.gz" ]]; then
            tar -czf "$bundle_file" -C "$INM_BACKUP_DIRECTORY" "$(basename -a "${bundle_parts[@]}")"
        else
            cat "${bundle_parts[@]}" > "$bundle_file"
        fi

        log ok "[BACKUP] Bundle created: $bundle_file"

        # Optionally: clean up parts
        rm -f "$db_file" "$storage_file" "$uploads_file"
    fi
}
cleanup_old_versions() {
    log info "[COV] Cleaning up old update directory versions."
    # todo: Sicherstellen, dass der name richtig ist. Wird in run_update() und run_installation() gesetzt.
    local update_dirs
    update_dirs=$(find "$INM_BASE_DIRECTORY" -maxdepth 1 -type d -name "$(basename "$INM_INSTALLATION_DIRECTORY")_*" | sort -r | tail -n +$((INM_KEEP_BACKUPS + 1)))

    if [ -n "$update_dirs" ]; then
        echo "$update_dirs" | xargs -r rm -rf || {
            log err "[COV] Failed to clean up old versions."
            exit 1
        }
    fi
    ls -la "$INM_BASE_DIRECTORY"
}
cleanup_old_backups() {
    log info "[COB] Cleaning up old backups."
    # todo: Sicherstellen, dass der name richtig ist. Wird in run_backup() gesetzt/erzeugt. Datum_mode_suffix. Damit dann richtig sortiert wird.
    local backup_path="$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY"
    local backup_items

    backup_items=$(find "$backup_path" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) | sort -r | tail -n +$((INM_KEEP_BACKUPS + 1)))

    if [ -n "$backup_items" ]; then
        echo "$backup_items" | xargs -r rm -rf || {
            log err "[COB] Failed to clean up old backup items."
            exit 1
        }
    fi
    log debug "[COB] Cleaning up done."
}
cleanup() {
    # ---------------------------------------------------------------------    
    # cleanup(): 
    #
    # Perform global cleanup of old artifacts related to Invoice Ninja installations.
    #
    # This includes:
    #   - Old update versions (e.g., versioned install directories)
    #   - Old backups (any files or folders in the backup directory beyond retention limit)
    #   - Cached download files (e.g., outdated tar archives)
    #
    #
    # Retention is controlled by $INM_KEEP_BACKUPS variable in .env.inmanage
    # All deletions are safe, sorted descending, and preserve the latest versions.
    # ----------------------------------------------------------------------

    cleanup_old_versions
    cleanup_old_backups
    cleanup_cache
}
spawn_provision_file() {
    # ---------------------------------------------------------------------
    # install()
    #
    # Initializes a fully automated Invoice Ninja installation using a 
    # provision file. This is a two-stage process:
    #
    #   1. Creates a provision file (based on .env.example from GitHub)
    #   2. Opens the file for editing (nano or vi)
    #   3. Terminates to allow editing
    #
    # On next execution, installation proceeds automatically:
    #   - Loads and validates required DB_* values
    #   - Connects to MySQL (optionally via elevated credentials)
    #   - Creates database and user (if not existing)
    #   - Downloads latest Invoice Ninja release
    #   - Sets up environment (.env), key, migration, cache, etc.
    #   - Creates admin
    #   - Shows you how to install cronjobs (Artisan scheduler + backup)
    #
    # Parameters (Named Arguments):
    #   --provision-file-target=./path/.env.provision
    #       Target location for newly generated provision file
    #
    #   --provision-file=./path/.env.provision
    #       Used on next run to trigger installation
    #
    #   --ninja-install-target=/var/www/your.domain/
    #       Optional target for Invoice Ninja installation if no config file is present
    #
    # If no parameters given Wizard will start with default values.
    #
    # Example usage:
    #   $SCRIPT_NAME install --provision-file-target=./.env.myproject.provision
    #
    # Follow-up installation:
    #   $SCRIPT_NAME --provision-file=./.env.myproject.provision --ninja-install-target=/var/www/myproject
    #
    # Manual alternative:
    #   1. Copy .env.example to .env.provision
    #   2. Fill in required APP_URL and DB_* values
    #   3. (Optional) Add DB_ELEVATED_USERNAME and DB_ELEVATED_PASSWORD
    #   4. Re-run $SCRIPT_NAME with Follow-up installation instructions.
    # ---------------------------------------------------------------------

    log info "[SPF] Generating provision file for unattended installation"
    log info "[SPF] This file will be used to configure Invoice Ninja setup"

    local target="${NAMED_ARGS[provision_file_target]:-$(prompt_var "Please enter a provision file path (default is .env.default-project.provision):" ".env.default-project.provision")}"
    INM_PROVISION_ENV_FILE="$target"

    local cache_dir
    cache_dir=$(resolve_cache_directory)

    if [ ! -d "$cache_dir" ]; then
        log err "[SPF] Cache directory $cache_dir does not exist. Please check your cache setup."
        exit 1
    fi

    INM_ENV_EXAMPLE_FILE="$cache_dir/.env.example"

    if [ ! -s "$INM_ENV_EXAMPLE_FILE" ]; then
        log info "[SPF] Downloading fresh .env.example from GitHub"
        curl -sL "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" \
            -o "$INM_ENV_EXAMPLE_FILE" || {
                log err "[SPF] Failed to download .env.example"
                exit 1
            }
    fi

    if [ -z "${NAMED_ARGS[ninja_run_installationget]}" ]; then
        local ninja_default_path="./invoiceninja"
        
        log info "[SPF] No ninja-install-target specified. The default path will be $ninja_default_path."
        
        if [ "${NAMED_ARGS[force]}" != true ]; then
            log note "[SPF] Do you want to proceed with the default target path '$ninja_default_path'? (y/n)"
            read -t 30 -n 1 response
            if [[ -z "$response" ]]; then
                log err "[SPF] No input provided, aborting installation."
                exit 1
            elif [[ "$response" != "y" && "$response" != "Y" ]]; then
                log err "[SPF] Installation aborted by user."
                exit 1
            fi
        fi

        NAMED_ARGS[ninja_run_installationget]="$ninja_default_path"
    fi

    cp -f "$INM_ENV_EXAMPLE_FILE" "$target" || {
        log err "[SPF] Failed to copy .env.example to $target"
        exit 1
    }

    chmod 600 "$target" || {
        log warn "[SPF] Could not set 600 permissions on provision file"
    }

    log ok "[SPF] Provision file created at $target"

    for key in APP_URL DB_HOST DB_DATABASE DB_USERNAME DB_PASSWORD; do
        if grep -q "^$key=" "$target"; then
            sed -i -E "s|^($key=.*?)(\s*(#.*)?)?\$|\1\t\t# MANDATORY|" "$target"
        fi
    done

    for key in DB_ELEVATED_USERNAME DB_ELEVATED_PASSWORD; do
        if grep -q "^$key=" "$target"; then
            sed -i -E "s|^($key=.*?)(\s*(#.*)?)?\$|\1\t\t# OPTIONAL for DB creation|" "$target"
        fi
    done

    if command -v nano >/dev/null; then
        log info "[SPF] Opening provision file in nano: $target"
        nano "$target"
    elif command -v vi >/dev/null; then
        log info "[SPF] Opening provision file in vi: $target"
        vi "$target"
    elif [ -n "$EDITOR" ] && command -v "$EDITOR" >/dev/null; then
        log info "[SPF] Opening provision file using \$EDITOR: $EDITOR"
        "$EDITOR" "$target"
    else
        log warn "[SPF] No suitable text editor found – please edit manually: $target"
    fi

    log important "[SPF] After editing, rerun the script with:"
    log bold "             $SCRIPT_NAME --provision-file=\"$target\" --ninja-install-target=/var/www/your.domain/invoiceninja"
    exit 0
}
show_function_help() {
    local fn="$1"
    local file="$0"
    # shellcheck disable=SC2034
    local in_func=0 in_comment=0

    log debug "[SFH] Showing help for function: $fn"
    log debug "[SFH] Using source file: $file"

    awk -v fn="$fn" '
        $0 ~ "^"fn"[[:space:]]*\\(\\)[[:space:]]*\\{" {
            in_func = 1; next
        }

        in_func {
            if ($0 ~ /^[[:space:]]*#[[:space:]]*-{3,}/) { in_comment = 1; next }

            if (in_comment && $0 ~ /^[[:space:]]*#/) {
                sub(/^[[:space:]]*#[[:space:]]?/, "")
                print
                next
            }

            if (in_comment) { exit }
        }
    ' "$file" | while IFS= read -r line; do
        case "$line" in
            "$fn()"*)     printf "\n${BOLD}${BLUE}%s${RESET}\n" "$line" ;;
            Behavior:|Parameters:|Globals:|Example:)
                         printf "\n${BOLD}${GREEN}%s${RESET}\n" "$line" ;;
            "")           printf "\n" ;;
            *)            printf "  %s\n" "$line" ;;
        esac
    done
    printf "\n\n"
}
show_help() {
    printf "Usage: %s <command> [args] [options] \n\n" "$0"
    printf "Docs:  https://github.com/DrDBanner/inmanage/#readme\n\n"

    printf "%bCommands:%b\n" "$BLUE" "$RESET"
    printf "  %-20s %s\n" "update"            "Update Invoice Ninja"
    printf "  %-20s %s\n" "backup"            "Backup Invoice Ninja DB and/or files (versioned)"
    printf "  %-20s %s\n" "install"           "Start Invoice Ninja setup (Wizard)"
    printf "  %-20s %s\n" "create_db"         "Create a fresh database with new user (elevated credentials)"
    printf "  %-20s %s\n" "import_db"         "Import SQL dump into Invoice Ninja DB"
    printf "  %-20s %s\n" "clean_install"     "Install clean from scratch (manual setup)"
    printf "  %-20s %s\n" "cleanup"           "Housekeeping: remove old atomic snapshots, backups and caches"
    printf "  %-20s %s\n" "install_cronjob"   "Install artisan/backup cronjobs"
    printf "  %-20s %s\n" "create_config"     "Create a new custom config file for a new inmanage + Invoice Ninja installation"
    printf "  %-20s %s\n" "reg_on_cli"        "Register this script on the CLI as 'inmanage' and 'inm' command"

    printf "\n%bOptions:%b\n" "$BLUE" "$RESET"
    printf "  %-20s %s\n" "--force"           "Force action even if up-to-date"
    printf "  %-20s %s\n" "--debug"           "Enable debug logging"
    printf "  %-20s %s\n" "-h, --help"        "Show global or command help. ${RED}Each command has its own help.${RESET}"
    printf "\n"
}


# todo: thik about it
#| Context | Action | Syntax                                                                       | Description                                                                                                                                                            | Flags                              |
#|---------|--------|------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------|
#| core    | clear-cache  | `inm core clear-cache <environment>`                                | Clears all caches (Redis, file-cache, views, config).                                                                   | –                                  |
#| core    | install      | `inm core install <environment> [--version=<version>] [--force]`    | Installs or reinstalls Invoice-Ninja; latest if no version given.                                                        | `--version`, `--force`             |
#| core    | provision    | `inm core provision <environment> [--version=<version>] [--force]`  | Installs Invoice-Ninja with a preconfigured .env file. If no version is given, latest is used.                                                                               | `--version`, `--force`             |
#| core    | info         | `inm core info <environment> [--verbose]`                           | Shows server-environment details: OS, kernel, CPU, memory, disk usage (quota), PHP version & settings, PHP extensions, DB type & version, webserver & PHP-FPM status, current user, application .env values., indicate dependencies met and give advice `--format`, `--filter` Performs health checks (DB connection, permissions, cron jobs). | `--verbose`                        |
#| core    | update       | `inm core update <environment> [--force] [--no-downtime]`           | Fetches latest release, runs migrations, atomic switch.                                                                    | `--force`, `--no-downtime`         |
#| core    | version      | `inm core version <environment>`                                    | Shows the installed Invoice-Ninja version.                                                                                 | –                                  |
#| db      | backup       | `inm db backup <environment> [--out=<file>] [--gzip]`               | Dumps the database to `<file>`, optionally compressing.                                                                    | `--out`, `--gzip`                  |
#| db      | prune        | `inm db prune <environment> [--keep=<count>]`                       | Deletes old backups, keeping at most `<count>`.                                                                            | `--keep`                           |
#| db      | restore      | `inm db restore <environment> --input=<file> [--dry-run]`           | Restores the database from `<file>`.                                                                                        | `--input`, `--dry-run`             |
#| files   | backup       | `inm files backup <environment> [--out=<dir>] [--archive]`          | Archives `storage/` & `public/uploads` into `<dir>`. Maybe it should diff compare to clean install folder. Should have a switch to copy over symlinked content as static copy.                                                                         | `--out`, `--archive`               |
#| files   | prune        | `inm files prune <environment> [--keep=<count>]`                    | Deletes old file backups, keeping at most `<count>`.                                                                         | `--keep`                           |
#| files   | restore      | `inm files restore <environment> --input=<archive> [--dry-run]`     | Restores files from `<archive>`.                                                                                            | `--input`, `--dry-run`             |
#| env     | set          | `inm env set <environment> <key>=<value>`                           | Sets or updates a key-value pair in the application .env file. If the key already exists, it will be updated.                                                                | –                                  |
#| env     | unset        | `inm env unset <environment> <key>`                                 | Removes a key-value pair from the application .env file. If the key does not exist, it will be ignored.                                                                        | –                                  |

# dispatcher
parse_options() {
    force_update=false
    DEBUG=false
    DRY_RUN=false
    command=""
    SHOW_FUNCTION_HELP=false

    declare -gA NAMED_ARGS

    while [[ $# -gt 0 ]]; do
        case "$1" in
            create_config)       command="create_own_config" ;;
            reg_on_cli)          command="reg_on_cli" ;;
            clean_install)       command="run_installation" ;;
            install)             command="spawn_provision_file" ;;
            update)              command="run_update" ;;
            backup)              command="run_backup" ;;
            create_db)           command="create_database" ;;
            import_db)           command="import_database" ;;
            cleanup)             command="cleanup" ;;
            cleanup_versions)    command="cleanup_versions" ;;
            cleanup_backups)     command="cleanup_backups" ;;
            install_cronjob)     command="install_cronjob" ;;
            --force)             force_update=true ;;
            --debug)             DEBUG=true ;;
            --dry-run)           DRY_RUN=true ;;
            -h|--help)           SHOW_FUNCTION_HELP=true ;;
            *=*)
                key="${1%%=*}"
                value="${1#*=}"
                NAMED_ARGS["$key"]="$value"
                ;;
            *)
                log err "Unknown option or command: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

clear
print_logo

parse_options "$@"

if [ "$DEBUG" = true ]; then
    printf -v _args '%q ' "$@"
    log debug "Args after: $_args"
fi

if [[ "$SHOW_FUNCTION_HELP" == true && -n "$command" ]]; then
log debug "[SFH PO] Showing help for command: $command"
            log debug "[SFHPO] Current user: $(whoami)"
            log debug "[SFHPO] Current shell: $SHELL"
    show_function_help "$command"
    exit 0
fi

check_commands
check_envs "$@"
check_gh_credentials

log debug "Command to run: $command"
log debug "Force: $force_update | Debug: $DEBUG | Dry-Run (not implemented): $DRY_RUN"

if [ -n "$command" ]; then
    log debug "Running command: $command"

    if declare -f "$command" > /dev/null; then
        log debug "[CMD] Executing command function: $command"
        cmd_args=()
        for key in "${!NAMED_ARGS[@]}"; do
            cmd_args+=("--$key=${NAMED_ARGS[$key]}")
        done
        "$command" "${cmd_args[@]}"
    else
        log err "Unknown command function: $command"
        exit 1
    fi
else
    if [[ "$SHOW_FUNCTION_HELP" == true ]]; then
        show_help
    else
        log info "No command specified. Nothing executed. Use -h for help."
    fi
fi



