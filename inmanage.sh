#!/usr/bin/env bash

set -e

[[ -n "$BASH_VERSION" ]] || {
    log err "This script requires Bash."

    if [ -f ".inmanage/.env.inmanage" ]; then
        user=$(grep '^INM_ENFORCED_USER=' .inmanage/.env.inmanage | cut -d= -f2 | tr -d '"')
        log info "Try: sudo -u ${user:-{your-user}} bash ./inmanage.sh"
    else
        log info "Try: sudo -u {your-user} bash ./inmanage.sh"
    fi

    exit 1
}

## Self configuration
INM_SELF_ENV_FILE=".inmanage/.env.inmanage"
INM_PROVISION_ENV_FILE=".inmanage/.env.provision"

## Globals
CURL_AUTH_FLAG=""

# ===== Color Setup: only if output is a terminal =====
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    WHITE='\033[1;37m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN=''; RED=''; CYAN=''; YELLOW=''; BLUE=''; WHITE=''; BOLD=''; RESET=''
fi

# ====== Logging ======
log() {
    #printf "${WHITE}%s [INFO] Logger starts %s${RESET}\n"
    local type="$1"; shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$type" in
        debug)
            if [ "$DEBUG" = true ]; then
                printf "${CYAN}%s [DEBUG] %s${RESET}\n" "$timestamp" "$*"
            fi
            ;;
        info)    printf "${WHITE}%s [INFO] %s${RESET}\n" "$timestamp" "$*" ;;
        ok)      printf "${GREEN}%s [OK] %s${RESET}\n" "$timestamp" "$*" ;;
        warn)    printf "${YELLOW}%s [WARN] %s${RESET}\n" "$timestamp" "$*" ;;
        err)     printf "${RED}%s [ERR] %s${RESET}\n" "$timestamp" "$*" ;;
        bold)    printf "${BOLD}%s [BOLD] %s${RESET}\n" "$timestamp" "$*" ;;
        *)       echo "$*" ;;
    esac
}

# ====== Array Setup ======
declare -A default_settings=(
    ["INM_BASE_DIRECTORY"]="$PWD/"
    ["INM_INSTALLATION_DIRECTORY"]="./invoiceninja"
    ["INM_ENV_FILE"]="\${INM_BASE_DIRECTORY}\${INM_INSTALLATION_DIRECTORY}/.env"
    ["INM_TEMP_DOWNLOAD_DIRECTORY"]="./._in_tempDownload"
    ["INM_DUMP_OPTIONS"]="--default-character-set=utf8mb4 --no-tablespaces --skip-add-drop-table --quick --single-transaction"
    ["INM_BACKUP_DIRECTORY"]="./_in_backups"
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
    ["INM_FORCE_READ_DB_PW"]="Include DB password in backup? (Y): May expose the password to other server users during runtime. (N): Assumes a secure .my.cnf file with credentials to avoid exposure."
    ["INM_ENFORCED_USER"]="Script user? Usually the webserver user. Ensure it matches your webserver setup."
    ["INM_ENFORCED_SHELL"]="Which shell should be used? In doubt, keep as is."
    ["INM_PHP_EXECUTABLE"]="Path to the PHP executable? In doubt, keep as is."
    ["INM_KEEP_BACKUPS"]="Backup retention? Set to 7 for daily backups to keep 7 snapshots. Ensure enough disk space."
    ["INM_GH_API_CREDENTIALS"]="GitHub API credentials may be required on shared hosting. Use the format username:password or token:x-oauth. If provided, all curl commands will use these credentials;"
)

prompt_var() {
    local var="$1"
    local default="$2"
    local text="${prompt_texts[$var]}"
    read -r -p "$(echo -e "${BLUE}${text}${NC} ${WHITE}[$default]${NC} > ")" input
    echo "${input:-$default}"
}

parse_options() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force_update=true
                ;;
            --debug)
                DEBUG=true
                ;;
            update|backup|clean_install|cleanup_versions|cleanup_backups)
                command=$1
                ;;
            *)
                log warn "Usage: ./inmanage.sh <update|backup|clean_install|cleanup_versions|cleanup_backups> [--force] [--debug] ..."
                exit 1
                ;;
        esac
        shift
    done
}

create_database() {
  local username="$1"
  local password="$2"

  if [ -z "$username" ]; then
    username=$(prompt "DB_ELEVATED_USERNAME" "" "Enter a DB username with create database permissions.")
    log info "Enter the password (input will be hidden):"
    read -s password
  fi

  if [ -z "$password" ]; then
    log info "No password given: Assuming .my.cnf credentials connection."
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$username" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_DATABASE DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER IF NOT EXISTS '$DB_USERNAME'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_DATABASE.* TO '$DB_USERNAME'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;

CREATE USER IF NOT EXISTS '$DB_USERNAME'@'$DB_HOST' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_DATABASE.* TO '$DB_USERNAME'@'$DB_HOST' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
  else
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$username" -p"$password" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_DATABASE DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER IF NOT EXISTS '$DB_USERNAME'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_DATABASE.* TO '$DB_USERNAME'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;

CREATE USER IF NOT EXISTS '$DB_USERNAME'@'$DB_HOST' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_DATABASE.* TO '$DB_USERNAME'@'$DB_HOST' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
  fi

  if [ $? -eq 0 ]; then
    log ok "Database and user created successfully. If they already existed, they were untouched. Privileges were granted."
    if [ -f "$INM_PROVISION_ENV_FILE" ]; then
      sed -i '/^DB_ELEVATED_USERNAME/d' "$INM_PROVISION_ENV_FILE"
      sed -i '/^DB_ELEVATED_PASSWORD/d' "$INM_PROVISION_ENV_FILE"
      log info "Removed DB_ELEVATED_USERNAME and DB_ELEVATED_PASSWORD from $INM_PROVISION_ENV_FILE if they were there."
    else
      log warn "$INM_PROVISION_ENV_FILE not found, cannot remove elevated credentials."
    fi
  else
    log err "Failed to create database and user."
    exit 1
  fi
}

check_provision_file() {
  if [ -f "$INM_PROVISION_ENV_FILE" ]; then
    . "$INM_PROVISION_ENV_FILE"

    if [ -z "$DB_HOST" ] || [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ] || [ -z "$DB_PORT" ]; then
      log err "Some DB variables are missing in provision file."
      exit 1
    fi

    log ok "Provision file loaded. Installation starts now."

    if [ -n "$DB_ELEVATED_USERNAME" ]; then
      log info "Elevated SQL user $DB_ELEVATED_USERNAME found in $INM_PROVISION_ENV_FILE."
      elevated_username="$DB_ELEVATED_USERNAME"
      elevated_password="$DB_ELEVATED_PASSWORD"
    else
      log info "No elevated SQL username found. Continuing with standard credentials."
      elevated_username=""
      elevated_password=""
    fi


    if [ -n "$elevated_username" ]; then
      if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e 'quit'; then
        log ok "Elevated credentials: Connection successful."
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e "use $DB_DATABASE"; then
          log ok "Connection Possible. Database already exists."
        else
          log warn "Connection Possible. Database does not exist."
          log info "Trying to create database now."
          create_database "$elevated_username" "$elevated_password"
        fi
      else
        log err "Failed to connect using elevated credentials. Check your elevated DB credentials and connection settings."
        if [ -z "$elevated_password" ]; then
          elevated_password=$(prompt "DB_ELEVATED_PASSWORD" "" "Enter the password for elevated user")
        fi
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e 'quit'; then
          log debug "Connection successful with provided elevated credentials."
          if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e "use $DB_DATABASE"; then
            log ok "Connection Possible. Database already exists."
          else
            create_database "$elevated_username" "$elevated_password"
          fi
        else
          exit 1
        fi
      fi
    else
      log info "No elevated credentials available. Trying to connect with standard user."
      if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e 'quit'; then
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "use $DB_DATABASE"; then
          log ok "Connection Possible. Database already exists."
        else
          create_database "$DB_USERNAME" "$DB_PASSWORD"
        fi
      else
        log err "Failed to connect to the database with standard credentials. Check your DB credentials and connection settings."
        exit 1
      fi
    fi
    install_tar "Provisioned"
  else
    log debug "No provision."
  fi
}

# shellcheck source=.inmanage/.env.inmanage
check_env() {
    log debug "Environment check starts."
    if [ ! -f "$INM_SELF_ENV_FILE" ]; then
        log warn "$INM_SELF_ENV_FILE configuration file for this script not found. Attempting to create it..."
        create_own_config
    else
        log debug "Self configuration found"
        # shellcheck source=.inmanage/.env.inmanage
        . "$INM_SELF_ENV_FILE"
        if [ "$(whoami)" != "$INM_ENFORCED_USER" ]; then
            INM_SCRIPT_PATH=$(realpath "$0")
            log info "Switching to user '$INM_ENFORCED_USER'."
            exec sudo -u "$INM_ENFORCED_USER" bash "$INM_SCRIPT_PATH" "$@"
            exit 0
        fi
        check_missing_settings
        check_provision_file
    fi
}

check_gh_credentials() {
    . "$INM_SELF_ENV_FILE"
    if [[ -n "$INM_GH_API_CREDENTIALS" && "$INM_GH_API_CREDENTIALS" == *:* ]]; then
        CURL_AUTH_FLAG="-u $INM_GH_API_CREDENTIALS"
        log info "GH Authentication detected. Curl commands will include credentials."
    else
        CURL_AUTH_FLAG=""
        log info "No GH credentials set. If connection fails, try to add credentials."
    fi
}

create_own_config() {
    if touch "$INM_SELF_ENV_FILE"; then
        log ok "Write Permissions OK."
        rm $INM_SELF_ENV_FILE
        echo -e " "
        echo -e "${YELLOW}========== Install Wizard ==========${NC}"
        echo -e " "
        log bold "Just press [ENTER] to accept defaults."
        echo -e " "

        # Prompt for variables in the order specified by prompt_order
        for key in "${prompt_order[@]}"; do
            value=${default_settings[$key]}
            prompt_text=${prompt_texts[$key]:-"Provide value for $key:"}
            default_settings[$key]=$(prompt_var "$key" "$value" "$prompt_text")
        done

        # Write variables to env file in the same order
        for key in "${prompt_order[@]}"; do
            echo "$key=\"${default_settings[$key]}\"" >> "$INM_SELF_ENV_FILE"
        done

        # Write any remaining default_settings not in prompt_order
        for key in "${!default_settings[@]}"; do
            found=0
            for ordered_key in "${prompt_order[@]}"; do
            if [[ "$key" == "$ordered_key" ]]; then
                found=1
                break
            fi
            done
            if [[ $found -eq 0 ]]; then
            echo "$key=\"${default_settings[$key]}\"" >> "$INM_SELF_ENV_FILE"
            fi
        done

        log ok "$INM_SELF_ENV_FILE has been created and configured."
        . "$INM_SELF_ENV_FILE"
        
        if [ -z "$INM_BASE_DIRECTORY" ]; then
            log err "Error: 'INM_BASE_DIRECTORY' variable is empty. Stopping script. File an issue on github."
            exit 1
        fi
        
        target="$INM_BASE_DIRECTORY.inmanage/inmanage.sh"
        link="$INM_BASE_DIRECTORY/inmanage.sh"

        if [ -L "$link" ]; then
            current_target=$(readlink "$link")
            if [ "$current_target" == "$target" ]; then
                log debug "The symlink is correct."
            else
                log warn "The symlink is incorrect. Updating."
                ln -sf "$target" "$link"
            fi
        else
            log debug "The symlink does not exist. Creating."
            ln -s "$target" "$link"
        fi

        env_example_file="$INM_BASE_DIRECTORY.inmanage/.env.example"
        log info "Downloading .env.example for provisioning"
        curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" -o "$env_example_file" || {
            log err "Failed to download .env.example for seeding"
            exit 1
        }

        if [ -f "$env_example_file" ]; then
            sed -i '/^DB_PORT=/a DB_ELEVATED_USERNAME=\nDB_ELEVATED_PASSWORD=' "$env_example_file"
        fi

        . "$INM_SELF_ENV_FILE"
        check_provision_file
    else
        log err "Error: Could not create $INM_SELF_ENV_FILE. Aborting configuration."
        exit 1
    fi
}

check_missing_settings() {
    updated=0
    for key in "${!default_settings[@]}"; do
        if ! grep -q "^$key=" "$INM_SELF_ENV_FILE"; then
            log warn "$key not found in $INM_SELF_ENV_FILE. Adding with default value '${default_settings[$key]}'."
            echo "$key=\"${default_settings[$key]}\"" >> "$INM_SELF_ENV_FILE"
            updated=1
        fi
    done
    if [ "$updated" -eq 1 ]; then
        log ok "Updated $INM_SELF_ENV_FILE with missing settings. Reloading."
        . "$INM_SELF_ENV_FILE"
    else
        log ok "Loaded settings from $INM_SELF_ENV_FILE."
    fi
}

check_commands() {
    local commands=("curl" "wc" "tar" "cp" "mv" "mkdir" "chown" "find" "rm" "mysqldump" "mysql" "grep" "xargs" "php" "touch" "sed" "sudo" "tee")
    local missing_commands=()

    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    local shell_builtins=("read")
    for builtin in "${shell_builtins[@]}"; do
        if ! type "$builtin" &>/dev/null; then
            log warn "Warning: Shell builtin '$builtin' not found – is this running in Bash?"
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log err "Error: The following commands are not available:"
        for missing in "${missing_commands[@]}"; do
            log err "  - $missing"
        done
        exit 1
    else
        log debug "All required external commands are available."
    fi
}

get_installed_version() {
    local version
    if [ -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/VERSION.txt" ]; then
        version=$(cat "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/VERSION.txt") || {
            log err "Failed to read installed version"
            exit 1
        }
        echo "$version"
    else
        log err "VERSION.txt not found"
        exit 1
    fi
}

get_latest_version() {
    local version
    version=$(curl -s ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} https://api.github.com/repos/invoiceninja/invoiceninja/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//') || {
        log err "Failed to retrieve latest version"
        exit 1
    }
    echo "$version"
}

download_ninja() {
    [ -d "$INM_TEMP_DOWNLOAD_DIRECTORY" ] && rm -Rf "$INM_TEMP_DOWNLOAD_DIRECTORY"
    mkdir -p "$INM_TEMP_DOWNLOAD_DIRECTORY" || {
        log err "Failed to create temp directory."
        exit 1
    }
    cd "$INM_TEMP_DOWNLOAD_DIRECTORY" || {
        log err "Failed to change to temp directory."
        exit 1
    }

    local app_version
    app_version=$(get_latest_version)
    sleep 2
    log info "Downloading Invoice Ninja version $app_version."

    temp_file="invoiceninja_temp.tar"

    if curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} -w "%{http_code}" "https://github.com/invoiceninja/invoiceninja/releases/download/v$app_version/invoiceninja.tar" -o "$temp_file" | grep -q "200"; then
        if [ $(wc -c < "$temp_file") -gt 1048576 ]; then
            mv "$temp_file" "invoiceninja.tar"
            log ok "Download successful."
        else
            log err "Download failed: File is too small. Please check network."
            rm "$temp_file"
            exit 1
        fi
    else
        log err "Download failed: HTTP-Statuscode not 200. Please check network. Maybe you need GitHub credentials."
        rm "$temp_file"
        exit 1
    fi
}

install_tar() {
    local mode="$1"
    local env_file

    if [ "$mode" == "Provisioned" ]; then
        env_file="$INM_BASE_DIRECTORY$INM_PROVISION_ENV_FILE"
    else
        env_file="$INM_INSTALLATION_DIRECTORY/.env.example"
    fi

    local latest_version

    latest_version=$(get_latest_version)

    if [ -d "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" ]; then
        log warn "Caution: Installation directory already exists! Current installation directory will get renamed. Proceed with installation? (yes/no): "
        if ! read -t 60 response; then
            log warn "No response within 60 seconds. Installation aborted."
            exit 0
        fi
        if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            log info "Installation aborted."
            exit 0
        fi
        mv "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" "_last_IN_$(date +'%Y%m%d_%H%M%S')"
    fi

    log info "Installation starts now"

    download_ninja

    mkdir "$INM_INSTALLATION_DIRECTORY" || {
        log err "Failed to create installation directory"
        exit 1
    }
    chown "$INM_ENFORCED_USER" "$INM_INSTALLATION_DIRECTORY" || {
        log err "Failed to change owner"
        exit 1
    }
    log info "Unpacking tar"
    tar -xzf invoiceninja.tar -C "$INM_INSTALLATION_DIRECTORY" || {
        log err "Failed to unpack"
        exit 1
    }
    mv "$env_file" "$INM_INSTALLATION_DIRECTORY/.env" || {
        log err "Failed to move .env file"
        exit 1
    }
    chmod 600 "$INM_INSTALLATION_DIRECTORY/.env" || {
        log err "Failed to chmod 600 .env file"
        exit 1
    }
    mv "$INM_INSTALLATION_DIRECTORY" "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" || {
        log err "Failed move installation to target directory $INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY"
        exit 1
    }
    log info "Generating Key"
    $INM_ARTISAN_STRING key:generate --force || {
        log err "Failed to generate key"
        exit 1
    }
    $INM_ARTISAN_STRING optimize || {
        log err "Failed to run optimize"
        exit 1
    }
    $INM_ARTISAN_STRING up || {
        log err "Failed to run artisan up"
        exit 1
    }
    if [ "$mode" == "Provisioned" ]; then
        $INM_ARTISAN_STRING migrate:fresh --seed --force || {
            log err "Failed to run artisan migrate"
            exit 1
        }
        $INM_ARTISAN_STRING ninja:create-account --email=admin@admin.com --password=admin && \
        {
            printf "\n${BLUE}%s${RESET}\n" "========================================"
            printf "${BOLD}${GREEN}Setup Complete!${RESET}\n\n"
            printf "${BOLD}Login:${RESET} ${CYAN}%s${RESET}\n" "$APP_URL"
            printf "${BOLD}Username:${RESET} admin@admin.com\n"
            printf "${BOLD}Password:${RESET} admin\n"
            printf "${BLUE}%s${RESET}\n\n" "========================================"
            printf "${WHITE}Open your browser at ${CYAN}%s${RESET} to access the application.${RESET}\n" "$APP_URL"
            printf "The database and user are configured.\n\n"
            printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
            printf "${BOLD}Cronjob Setup:${RESET}\n"
            printf "  ${CYAN}* * * * * $INM_ENFORCED_USER $INM_ARTISAN_STRING schedule:run >> /dev/null 2>&1${RESET}\n\n"
            printf "${BOLD}Scheduled Backup:${RESET}\n"
            printf "  ${CYAN}* 3 * * * $INM_ENFORCED_USER $INM_ENFORCED_SHELL -c \"$INM_BASE_DIRECTORY./inmanage.sh backup\" >> /dev/null 2>&1${RESET}\n\n"
        } || {
            log err "Standard user creation failed"
            exit 1
        }
        else
        printf "\n${BLUE}%s${RESET}\n" "========================================"
        printf "${BOLD}${GREEN}Setup Complete!${RESET}\n\n"
        printf "${WHITE}Open your browser at your configured address ${CYAN}https://your.url/setup${RESET} to carry on with database setup.${RESET}\n\n"
        printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
        printf "${BOLD}Cronjob Setup:${RESET}\n"
        printf "  ${CYAN}* * * * * $INM_ENFORCED_USER $INM_ARTISAN_STRING schedule:run >> /dev/null 2>&1${RESET}\n\n"
        printf "${BOLD}Scheduled Backup:${RESET}\n"
        printf "  ${CYAN}* 3 * * * $INM_ENFORCED_USER $INM_ENFORCED_SHELL -c \"$INM_BASE_DIRECTORY./inmanage.sh backup\" >> /dev/null 2>&1${RESET}\n\n"
        fi

    cd "$INM_BASE_DIRECTORY" && rm -Rf "$INM_TEMP_DOWNLOAD_DIRECTORY"
    exit 0
}

run_update() {
    local installed_version latest_version

    installed_version=$(get_installed_version)
    latest_version=$(get_latest_version)

    if [ "$installed_version" == "$latest_version" ] && [ "$force_update" != true ]; then
        log info "Already up-to-date. Proceed with update? (yes/no): "
        if ! read -t 60 response; then
            log warn "No response within 60 seconds. Update aborted."
            exit 0
        fi
        if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            log info "Update aborted."
            exit 0
        fi
    fi

    log info "Update starts now."
    download_ninja
    mkdir "$INM_INSTALLATION_DIRECTORY" || {
        log err "Failed to create installation directory"
        exit 1
    }
    chown "$INM_ENFORCED_USER" "$INM_INSTALLATION_DIRECTORY" || {
        log err "Failed to change owner"
        exit 1
    }
    log info "Unpacking Data."
    tar -xzf invoiceninja.tar -C "$INM_INSTALLATION_DIRECTORY" || {
        log err "Failed to unpack"
        exit 1
    }
    $INM_ARTISAN_STRING cache:clear || {
        log err "Failed to clear artisan cache"
        exit 1
    }
    $INM_ARTISAN_STRING down || {
        log err "Failed to run artisan down"
        exit 1
    }
    cp "$INM_ENV_FILE" "$INM_INSTALLATION_DIRECTORY/" || {
        log err "Failed to copy .env"
        exit 1
    }
    if [ -d "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/" ]; then
        cp -R "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/." "$INM_INSTALLATION_DIRECTORY/public/storage/" || {
            log warn "Failed to copy storage from $INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/."
        }
    else
        log info "Directory does not exist: $INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/"
        log info "This may be normal if this is an initial installation, or if your storage is located somewhere different. You may need to copy data manually."
    fi

    if compgen -G "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/"*.ini > /dev/null; then
        cp -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/"*.ini "$INM_INSTALLATION_DIRECTORY/public/"
    fi
    if compgen -G "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/".*.ini > /dev/null; then
        cp -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/".*.ini "$INM_INSTALLATION_DIRECTORY/public/"
    fi
    if [[ -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/.htaccess" ]]; then
        cp -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/.htaccess" "$INM_INSTALLATION_DIRECTORY/public/"
    fi

    mv "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$(date +'%Y%m%d_%H%M%S')" || {
        log err "Failed to rename old installation"
        exit 1
    }
    chmod 600 "$INM_INSTALLATION_DIRECTORY/.env" || {
        log warn "Failed to chmod 600 .env file. Please check what's wrong."
    }
    old_version_dir="$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$(date +'%Y%m%d_%H%M%S')"
    if [ -f "$old_version_dir/public/storage/framework/down" ]; then
        rm "$old_version_dir/public/storage/framework/down" || {
            log err "Failed to remove 'Maintenance' file from $old_version_dir/public/storage/framework/"
            exit 1
        }
        log ok "'Maintenanace' file removed from $old_version_dir/public/storage/framework/."
    fi
    if [ -f "$old_version_dir/storage/framework/down" ]; then
        rm "$old_version_dir/storage/framework/down" || {
            log err "Failed to remove 'Maintenance' file from $old_version_dir/storage/framework/"
            exit 1
        }
        log ok "'Maintenanace' file removed from $old_version_dir/storage/framework/."
    fi
    mv "$INM_BASE_DIRECTORY$INM_TEMP_DOWNLOAD_DIRECTORY/$INM_INSTALLATION_DIRECTORY" "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" || {
        log err "Failed to move new installation"
        exit 1
    }
    $INM_ARTISAN_STRING optimize || {
        log err "Failed to artisan optimize"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:post-update || {
        log err "Failed to run post-update"
        exit 1
    }
    $INM_ARTISAN_STRING migrate --force || {
        log err "Failed to run artisan migrate"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:check-data || {
        log err "Failed to run check data"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:translations || {
        log err "Failed to run translations"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:design-update || {
        log err "Failed to run design-update"
        exit 1
    }
    $INM_ARTISAN_STRING up || {
        log err "Failed to run artisan up"
        exit 1
    }

    . "$INM_ENV_FILE"

    if [ "$PDF_GENERATOR" = "snappdf" ]; then
        log info "Snappdf configuration detected."
        if [ -n "$SNAPPDF_CHROMIUM_PATH" ]; then
            log info "Chromium path is set to '$SNAPPDF_CHROMIUM_PATH'. Skipping ungoogled chrome download via SNAPPDF_SKIP_DOWNLOAD."
            export SNAPPDF_SKIP_DOWNLOAD=true
        fi
        cd "${INM_BASE_DIRECTORY}${INM_INSTALLATION_DIRECTORY}"
        if [ ! -x "./vendor/bin/snappdf" ]; then
            log debug "The file ./vendor/bin/snappdf is not executable. Adding executable flag."
            chmod +x ./vendor/bin/snappdf
        fi
        log debug "Download and install Chromium if needed."
        $INM_PHP_EXECUTABLE ./vendor/bin/snappdf download
    else
        log info "PDF generation is set to '$PDF_GENERATOR'"
    fi
    cleanup_old_versions
    log ok "Update completed successfully!"
}

run_backup() {
    if [ ! -d "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY" ]; then
        log info "Creating backup directory."
        mkdir -p "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY" || {
            log err "Failed to create backup directory"
            exit 1
        }
    else
        log debug "Backup directory exists."
    fi

    if [ -f "$INM_ENV_FILE" ]; then
        local export_vars
        export_vars=$("$INM_ENFORCED_SHELL" -c "grep '^DB_' '$INM_ENV_FILE' | xargs") || {
            log err "Failed to extract DB variables."
            exit 1
        }
        eval "$export_vars" || {
            log err "Failed to evaluate DB variables."
            exit 1
        }

        if [ -z "$DB_HOST" ] || [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ] || [ -z "$DB_PORT" ]; then
            log err "Some DB variables are missing."
            exit 1
        fi
    fi

    cd "$INM_BACKUP_DIRECTORY" || {
        log err "Failed to change to backup directory."
        exit 1
    }

    if [ "$INM_FORCE_READ_DB_PW" == "Y" ]; then
        log info "Dumping database..."
        mysqldump $INM_DUMP_OPTIONS -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" | tee "${DB_DATABASE}_$(date +'%Y%m%d_%H%M%S').sql" > /dev/null || {
            log err "Failed to dump database."
            exit 1
        }
        log ok "Database dump done."
    else
        log info "Using .my.cnf file for database selection and access."
        log info "Dumping database..."
        mysqldump $INM_DUMP_OPTIONS -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE" | tee "${DB_DATABASE}_$(date +'%Y%m%d_%H%M%S').sql" > /dev/null || {
            log err "Failed to dump database."
            exit 1
        }
        log ok "Database dump done."
    fi

    cd "$INM_BASE_DIRECTORY" || {
        log err "Failed to change to base-directory."
        exit 1
    }
    log info "Compressing Data. This may take a while. Hang on..."
    tar -czf "${INM_PROGRAM_NAME}_$(date +'%Y%m%d_%H%M%S').tar.gz" "$INM_BACKUP_DIRECTORY"/*.sql -C "$INM_INSTALLATION_DIRECTORY" . || {
        log err "Failed to create backup."
        exit 1
    }
    rm "$INM_BACKUP_DIRECTORY"/*.sql || {
        log err "Failed to remove SQL files."
        exit 1
    }
    mv ${INM_PROGRAM_NAME}_*.tar.gz "$INM_BACKUP_DIRECTORY" || {
        log err "Failed to move backup."
        exit 1
    }

    cleanup_old_backups
    log ok "Backup completed successfully!"
}

cleanup_old_versions() {
    log info "Cleaning up old update directory versions."
    local update_dirs
    update_dirs=$(find "$INM_BASE_DIRECTORY" -maxdepth 1 -type d -name "$(basename "$INM_INSTALLATION_DIRECTORY")_*" | sort -r | tail -n +$((INM_KEEP_BACKUPS + 1)))

    if [ -n "$update_dirs" ]; then
        echo "$update_dirs" | xargs -r rm -rf || {
            log err "Failed to clean up old versions."
            exit 1
        }
    fi
    rm -Rf "$INM_TEMP_DOWNLOAD_DIRECTORY"
    ls -la "$INM_BASE_DIRECTORY"
}

cleanup_old_backups() {
    log info "Cleaning up old backups."
    local backup_files
    backup_files=$(find "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY" -maxdepth 1 -type f -name "*.tar.gz" | sort -r | tail -n +$((INM_KEEP_BACKUPS + 1)))

    if [ -n "$backup_files" ]; then
        echo "$backup_files" | xargs -r rm -f || {
            log err "Failed to clean up old backups."
            exit 1
        }
    fi
    rm -Rf "$INM_TEMP_DOWNLOAD_DIRECTORY"
    ls -la "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY"
}

function_caller() {
    case "$1" in
    clean_install)
        install_tar
        ;;
    update)
        run_update
        ;;
    backup)
        run_backup
        ;;
    create_db)
        create_database
        ;;
    cleanup_versions)
        cleanup_old_versions
        ;;
    cleanup_backups)
        cleanup_old_backups
        ;;
    *)
        return 1
        ;;
    esac
}

command=""
parse_options "$@"

force_update=false

check_commands
check_env "$@"
check_gh_credentials

log debug "$0='$0' $1='$1' $2='$2' \$@='$@' \$*='$*'"

if [ -z "$command" ]; then
    log warn "Usage: ./inmanage.sh <update|backup|clean_install|cleanup_versions|cleanup_backups> [--force] [--debug] Full Documentation https://github.com/DrDBanner/inmanage/#readme"
    exit 1
fi

cd "$INM_BASE_DIRECTORY" && function_caller "$command"