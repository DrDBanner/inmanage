#!/bin/bash
set -e

## Self configuration
INM_SELF_ENV_FILE=".inmanage/.env.inmanage"
INM_PROVISION_ENV_FILE=".inmanage/.env.provision"

# Function to prompt for user input
prompt() {
    local var_name="$1"
    local default_value="$2"
    local prompt_message="$3"

    while true; do
        read -r -p "${prompt_message} [default: $default_value]: " input
        if [ -z "$input" ]; then
            input="$default_value"
        fi
        if [ -n "$input" ]; then
            echo "$input"
            return
        else
            echo "Invalid input. Please try again."
        fi
    done
}

## Create Database
## Consumes parameters for the connection like: create_database "$DB_ELEVATED_USERNAME" "$DB_ELEVATED_PASSWORD"
## If username is missing, it prompts for user input. If password is missing it tries to connect with elevated user only.

create_database() {
  local username="$1"
  local password="$2"

  if [ -z "$username" ]; then
    username=$(prompt "DB_ELEVATED_USERNAME" "" "Enter a DB username with create database permissions.")
    echo "Enter the password (input will be hidden):"
    read -s password
  fi

  # Create database and user
  if [ -z "$password" ]; then
    echo -e "No password given: Assuming .my.cnf credentials connection."
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
    echo "Database and user created successfully. If they already existed, they were untouched. Privileges were granted."

    # Remove DB_ELEVATED_USERNAME and DB_ELEVATED_PASSWORD from INM_PROVISION_ENV_FILE
    if [ -f "$INM_PROVISION_ENV_FILE" ]; then
      sed -i '/^DB_ELEVATED_USERNAME/d' "$INM_PROVISION_ENV_FILE"
      sed -i '/^DB_ELEVATED_PASSWORD/d' "$INM_PROVISION_ENV_FILE"
      echo "Removed DB_ELEVATED_USERNAME and DB_ELEVATED_PASSWORD from $INM_PROVISION_ENV_FILE if they were there."
    else
      echo "$INM_PROVISION_ENV_FILE not found, cannot remove elevated credentials."
    fi
  else
    echo "Failed to create database and user."
    exit 1
  fi
}


## Check for .env for installation provisioning, create db, move IN config to target
check_provision_file() {
  if [ -f "$INM_PROVISION_ENV_FILE" ]; then
    source "$INM_PROVISION_ENV_FILE"

    if [ -z "$DB_HOST" ] || [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ] || [ -z "$DB_PORT" ]; then
      echo "Some DB variables are missing in provision file."
      exit 1
    fi

    # Check for elevated credentials
    if [ -n "$DB_ELEVATED_USERNAME" ]; then
      echo "Elevated SQL user $DB_ELEVATED_USERNAME found in $INM_PROVISION_ENV_FILE."
      elevated_username="$DB_ELEVATED_USERNAME"
      elevated_password="$DB_ELEVATED_PASSWORD"
    else
      echo "No elevated SQL username found. Continuing with standard credentials."
      elevated_username=""
      elevated_password=""
    fi

    echo "Provision file loaded. Checking database connection and database existence now."

    # Attempt connection using elevated credentials if available
    if [ -n "$elevated_username" ]; then
      if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e 'quit'; then
        echo "Elevated credentials: Connection successful."
        # Check if database exists
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e "use $DB_DATABASE"; then
          echo "Connection Possible. Database already exists."
        else
          echo "Connection Possible. Database does not exist."
          echo "Trying to create database now."
          create_database "$elevated_username" "$elevated_password"
        fi
      else
        echo "Failed to connect using elevated credentials. Check your elevated DB credentials and connection settings."

        # Prompt for elevated password if not provided
        if [ -z "$elevated_password" ]; then
          elevated_password=$(prompt "DB_ELEVATED_PASSWORD" "" "Enter the password for elevated user")
        fi

        # Retry connection with the provided password
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e 'quit'; then
          echo "Connection successful with provided elevated credentials."
          # Check if database exists
          if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$elevated_username" -p"$elevated_password" -e "use $DB_DATABASE"; then
            echo "Connection Possible. Database already exists."
          else
            echo "Connection Possible. Database does not exist."
            echo "Trying to create database now."
            create_database "$elevated_username" "$elevated_password"
          fi
        else
          echo "Failed to connect with provided elevated credentials. Unable to proceed."
          exit 1
        fi
      fi
    else
      echo "No elevated credentials available. Trying to connect with standard user."

      # Check database connection using standard user credentials
      if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e 'quit'; then
        # Check if database exists
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "use $DB_DATABASE"; then
          echo "Connection Possible. Database already exists."
        else
          echo "Connection Possible. Database does not exist."
          echo "Trying to create database now."
          create_database "$DB_USERNAME" "$DB_PASSWORD"
        fi
      else
        echo "Failed to connect to the database with standard credentials. Check your DB credentials and connection settings."
        exit 1
      fi
    fi
    install_tar "Provisioned"
  else
    echo "No provision."
  fi
}

# Check and load the self environment file
check_env() {
    echo -e "Environment check starts."
  if [ ! -f "$INM_SELF_ENV_FILE" ]; then
    echo "$INM_SELF_ENV_FILE configuration file for this script not found. Attempting to create it..."
    create_own_config
  else
    echo -e "Self configuration found"
    source "$INM_SELF_ENV_FILE"
        # Ensure script runs as INM_ENFORCED_USER
        if [ "$(whoami)" != "$INM_ENFORCED_USER" ]; then
            INM_SCRIPT_PATH=$(realpath "$0")
            echo "Switching to user '$INM_ENFORCED_USER'."
            exec sudo -u "$INM_ENFORCED_USER" "$INM_ENFORCED_SHELL" -c "cd '$(pwd)' && \"$INM_SCRIPT_PATH\" \"$@\""
            exit 0
        fi
    check_provision_file
  fi
}

# Create config file and symlink in base directory
create_own_config() {
    # Temporarily create the file to check if it's possible
    if touch "$INM_SELF_ENV_FILE"; then
        echo "Write Permissions OK. Proceeding with configuration..."

        # Remove the file again in case the installation prompt isn't successful.
        rm $INM_SELF_ENV_FILE

        # Query for configuration
        echo -e "\n\n Just press [ENTER] to accept defaults. \n\n"
        INM_BASE_DIRECTORY=$(prompt "INM_BASE_DIRECTORY" "$PWD/" "Which directory contains your IN installation folder? Must have a trailing slash.")
        INM_INSTALLATION_DIRECTORY=$(prompt "INM_INSTALLATION_DIRECTORY" "./invoiceninja" "What is the installation directory name? Must be relative from $INM_BASE_DIRECTORY and can start with a . dot.")
        INM_ENV_FILE="$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/.env"
        INM_TEMP_DOWNLOAD_DIRECTORY="./._in_tempDownload"
        INM_BACKUP_DIRECTORY=$(prompt "INM_BACKUP_DIRECTORY" "./_in_backups" "Where shall backups go?")
        INM_FORCE_READ_DB_PW=$(prompt "INM_FORCE_READ_DB_PW" "N" "Include database password in backup command? If Y we read it from Invoice Ninja installation, but it's a security concern and may be visible for other server users while the task is running. If N the script assumes you have a secure and working .my.cnf file with your DB credentials. (Y/N)")
        INM_ENFORCED_USER=$(prompt "INM_ENFORCED_USER" "www-data" "The user running the script? Should be the webserver user in most cases. Check twice if this value is set correct according to your webserver's setup.")
        INM_ENFORCED_SHELL=$(prompt "INM_ENFORCED_SHELL" "$(command -v bash)" "Which shell should be used? In doubt, keep as is.")
        INM_PHP_EXECUTABLE=$(prompt "INM_PHP_EXECUTABLE" "$(command -v php)" "Path to the PHP executable? In doubt, keep as is.")
        INM_ARTISAN_STRING="$INM_PHP_EXECUTABLE $INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/artisan"
        INM_PROGRAM_NAME="InvoiceNinja"
        INM_COMPATIBILITY_VERSION="5+"
        INM_KEEP_BACKUPS=$(prompt "INM_KEEP_BACKUPS" "2" "How many backup files and update iterations to keep? If you keep 7 and backup on a daily basis you have 7 snapshots available.")

        # Save configuration to .env.inmanage
        cat <<EOL >$INM_SELF_ENV_FILE
INM_BASE_DIRECTORY="$INM_BASE_DIRECTORY"
INM_INSTALLATION_DIRECTORY="$INM_INSTALLATION_DIRECTORY"
INM_ENV_FILE="$INM_ENV_FILE"
INM_TEMP_DOWNLOAD_DIRECTORY="$INM_TEMP_DOWNLOAD_DIRECTORY"
INM_BACKUP_DIRECTORY="$INM_BACKUP_DIRECTORY"
INM_ENFORCED_USER="$INM_ENFORCED_USER"
INM_ENFORCED_SHELL="$INM_ENFORCED_SHELL"
INM_PHP_EXECUTABLE="$INM_PHP_EXECUTABLE"
INM_ARTISAN_STRING="$INM_ARTISAN_STRING"
INM_PROGRAM_NAME="$INM_PROGRAM_NAME"
INM_KEEP_BACKUPS="$INM_KEEP_BACKUPS"
INM_FORCE_READ_DB_PW="$INM_FORCE_READ_DB_PW"
EOL

        echo "$INM_SELF_ENV_FILE has been created and configured."

        target="$INM_BASE_DIRECTORY.inmanage/inmanage.sh"
        link="$INM_BASE_DIRECTORY/inmanage.sh"

        # Check if the link exists
        if [ -L "$link" ]; then
            # Check if it points to the correct target
            if [ "$(readlink "$link")" == "$target" ]; then
                echo "The symlink is correct."
            else
                echo "The symlink is incorrect. Updating..."
                ln -sf "$target" "$link"
            fi
        else
            echo "The symlink does not exist. Creating..."
            ln -s "$target" "$link"
        fi
    else
        echo "Error: Could not create $INM_SELF_ENV_FILE. Aborting configuration."
        exit 1
    fi
    env_example_file="$INM_BASE_DIRECTORY.inmanage/.env.example"
    echo "Downloading .env.example for provisioning"
    curl -sL "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" -o "$env_example_file" || {
        echo "Failed to download .env.example for seeding"
        exit 1
    }
    if [ -f "$env_example_file" ]; then
    sed -i '/^DB_PORT=/a DB_ELEVATED_USERNAME=\nDB_ELEVATED_PASSWORD=' "$env_example_file"
    fi
    source $INM_SELF_ENV_FILE
    check_provision_file
}

# Check required commands
check_commands() {
    local commands=("curl" "tar" "cp" "mv" "mkdir" "chown" "find" "rm" "mysqldump" "mysql" "grep" "xargs" "php" "read" "source" "touch" "sed")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: Command '$cmd' is not available. Please install it and try again."
            exit 1
        fi
    done
}

# Get installed version
get_installed_version() {
    local version
    if [ -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/VERSION.txt" ]; then
        version=$(cat "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/VERSION.txt") || {
            echo "Failed to read installed version"
            exit 1
        }
        echo "$version"
    else
        echo "VERSION.txt not found"
        exit 1
    fi
}

# Get latest version
get_latest_version() {
    local version
    version=$(curl -s https://api.github.com/repos/invoiceninja/invoiceninja/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//') || {
        echo "Failed to retrieve latest version"
        exit 1
    }
    echo "$version"
}

# Download Invoice Ninja
download_ninja() {
    [ -d "$INM_TEMP_DOWNLOAD_DIRECTORY" ] && rm -Rf "$INM_TEMP_DOWNLOAD_DIRECTORY"
    mkdir -p "$INM_TEMP_DOWNLOAD_DIRECTORY" || {
        echo "Failed to create temp directory"
        exit 1
    }
    cd "$INM_TEMP_DOWNLOAD_DIRECTORY" || {
        echo "Failed to change to temp directory"
        exit 1
    }

    local app_version
    app_version=$(get_latest_version)
    sleep 2
    echo "Downloading Invoice Ninja version $app_version..."
    curl -sL "https://github.com/invoiceninja/invoiceninja/releases/download/v$app_version/invoiceninja.tar" -o invoiceninja.tar || {
        echo "Failed to download"
        exit 1
    }
}

# Install tar
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
        echo -n "Caution: Installation directory already exists! Current installation directory will get renamed. Proceed with installation? (yes/no): "
        # Set a timeout for 60 seconds
        if ! read -t 60 response; then
            echo "No response within 60 seconds. Installation aborted."
            exit 0
        fi
        if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            echo "Installation aborted."
            exit 0
        fi
        mv "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" "_last_IN_$(date +'%Y%m%d_%H%M%S')"
    fi

    echo "Installation starts now"

    download_ninja

    mkdir "$INM_INSTALLATION_DIRECTORY" || {
        echo "Failed to create installation directory"
        exit 1
    }
    chown "$INM_ENFORCED_USER" "$INM_INSTALLATION_DIRECTORY" || {
        echo "Failed to change owner"
        exit 1
    }
    echo -e "Unpacking tar"
    tar -xzf invoiceninja.tar -C "$INM_INSTALLATION_DIRECTORY" || {
        echo "Failed to unpack"
        exit 1
    }
    mv "$env_file" "$INM_INSTALLATION_DIRECTORY/.env" || {
        echo "Failed to move .env file"
        exit 1
    }
    chmod 600 "$INM_INSTALLATION_DIRECTORY/.env" || {
        echo "Failed to chmod 600 .env file"
        exit 1
    }
    mv "$INM_INSTALLATION_DIRECTORY" "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" || {
        echo "Failed move installation to target directory $INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY"
        exit 1
    }
    echo -e "Generating Key" 
    $INM_ARTISAN_STRING key:generate --force || {
        echo "Failed to generate key"
        exit 1
    }
    $INM_ARTISAN_STRING optimize || {
        echo "Failed to run optimize"
        exit 1
    }
    $INM_ARTISAN_STRING up || {
        echo "Failed to run artisan up"
        exit 1
    }
    if [ "$mode" == "Provisioned" ]; then
    $INM_ARTISAN_STRING migrate --force || {
        echo "Failed to run artisan up"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:create-account --email=admin@admin.com --password=admin && echo -e "\n\n\ Login: $APP_URL Username: admin@admin.com Password: admin \n\n\" || {
        echo "Standard user creation failed"
        exit 1
    }
    echo -e "\n\n\
    Setup Complete!\n\n\
    Open your browser at $APP_URL to access the application.\n\
    The database and user are configured.\n\
    It's a good time to make your first backup!\n\n\
    Cronjob Setup:\n\
    Add this for scheduled tasks:\n\
    * * * * * $INM_ENFORCED_USER $INM_ARTISAN_STRING schedule:run >> /dev/null 2>&1\n\n\
    Scheduled Backup:\n\
    To schedule a backup, add this:\n\
    * 3 * * * $INM_ENFORCED_USER $INM_ENFORCED_SHELL -c \"$INM_BASE_DIRECTORY/inmanage.sh backup\" >> /dev/null 2>&1\n\n\
    "

    else
        echo -e "\n\n Open your browser at your configured address https://your.url/setup now to carry on with database setup. GOOD TIME TO MAKE YOUR FIRST BACKUP NOW! \n Don't forget to set the cronjob like: * * * * * $INM_ENFORCED_USER $INM_ARTISAN_STRING schedule:run >> /dev/null 2>&1 \n If you want to do a scheduled backup copy this cronjob to your crontab:  * 3 * * * $INM_ENFORCED_USER $INM_ENFORCED_SHELL -c \"$INM_BASE_DIRECTORY\inmanage.sh backup\" >> /dev/null 2>&1 \n\n"
    fi

    cd "$INM_BASE_DIRECTORY" && rm -Rf "$INM_TEMP_DOWNLOAD_DIRECTORY"
}

# Run update
run_update() {
    local installed_version latest_version

    installed_version=$(get_installed_version)
    latest_version=$(get_latest_version)

    if [ "$installed_version" == "$latest_version" ] && [ "$force_update" != true ]; then
        echo -e "Already up-to-date. Proceed with update? (yes/no): "
        # Set a timeout for 60 seconds
        if ! read -t 60 response; then
            echo "No response within 60 seconds. Update aborted."
            exit 0
        fi
        if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            echo "Update aborted."
            exit 0
        fi
    fi

    echo "Update starts now."
    download_ninja
    mkdir "$INM_INSTALLATION_DIRECTORY" || {
        echo "Failed to create installation directory"
        exit 1
    }
    chown "$INM_ENFORCED_USER" "$INM_INSTALLATION_DIRECTORY" || {
        echo "Failed to change owner"
        exit 1
    }
    echo -e "Unpacking Data."
    tar -xzf invoiceninja.tar -C "$INM_INSTALLATION_DIRECTORY" || {
        echo "Failed to unpack"
        exit 1
    }
    $INM_ARTISAN_STRING cache:clear || {
        echo "Failed to clear artisan cache"
        exit 1
    }
    $INM_ARTISAN_STRING down || {
        echo "Failed to run artisan down"
        exit 1
    }
    cp "$INM_ENV_FILE" "$INM_INSTALLATION_DIRECTORY/" || {
        echo "Failed to copy .env"
        exit 1
    }
    cp -R "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/." "$INM_INSTALLATION_DIRECTORY/public/storage/" || {
        echo "Failed to copy storage"
        exit 1
    }
    mv "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$(date +'%Y%m%d_%H%M%S')" || {
        echo "Failed to rename old installation"
        exit 1
    }
    # Remove the 'down' file if it exists in the versioned old directory
    old_version_dir="$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$(date +'%Y%m%d_%H%M%S')"
    if [ -f "$old_version_dir/public/storage/framework/down" ]; then
        rm "$old_version_dir/public/storage/framework/down" || {
            echo "Failed to remove 'Maintenance' file from $old_version_dir/public/storage/framework/"
            exit 1
        }
        echo "'Maintenanace' file removed from $old_version_dir/public/storage/framework/."
    fi
    mv "$INM_BASE_DIRECTORY$INM_TEMP_DOWNLOAD_DIRECTORY/$INM_INSTALLATION_DIRECTORY" "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" || {
        echo "Failed to move new installation"
        exit 1
    }
    $INM_ARTISAN_STRING optimize || {
        echo "Failed to artisan optimize"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:post-update || {
        echo "Failed to run post-update"
        exit 1
    }
    $INM_ARTISAN_STRING migrate --force || {
        echo "Failed to run artisan migrate"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:check-data || {
        echo "Failed to run check data"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:translations || {
        echo "Failed to run translations"
        exit 1
    }
    $INM_ARTISAN_STRING up || {
        echo "Failed to run artisan up"
        exit 1
    }

    cleanup_old_versions
}

# Run backup
run_backup() {
    if [ ! -d "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY" ]; then
        echo "Creating backup directory."
        mkdir -p "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY" || {
            echo "Failed to create backup directory"
            exit 1
        }
    else
        echo "Backup directory already exists. Using it."
    fi

    if [ -f "$INM_ENV_FILE" ]; then
        local export_vars
        export_vars=$("$INM_ENFORCED_SHELL" -c "grep '^DB_' '$INM_ENV_FILE' | xargs") || {
            echo "Failed to extract DB variables"
            exit 1
        }
        eval "$export_vars" || {
            echo "Failed to evaluate DB variables"
            exit 1
        }

        if [ -z "$DB_HOST" ] || [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ] || [ -z "$DB_PORT" ]; then
            echo "Some DB variables are missing."
            exit 1
        fi
    fi

    cd "$INM_BACKUP_DIRECTORY" || {
        echo "Failed to change to backup directory"
        exit 1
    }

    if [ "$INM_FORCE_READ_DB_PW" == "Y" ]; then
        mysqldump -f --no-create-db -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" >"${DB_DATABASE}_$(date +'%Y%m%d_%H%M%S').sql" || {
            echo "Failed to dump database"
            exit 1
        }
    else
        echo "Using .my.cnf for database access"
        mysqldump -f --no-create-db -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE" >"${DB_DATABASE}_$(date +'%Y%m%d_%H%M%S').sql" || {
            echo "Failed to dump database"
            exit 1
        }
    fi

    cd "$INM_BASE_DIRECTORY" || {
        echo "Failed to change to base directory"
        exit 1
    }
    echo -e "Compressing Data. This may take a while. Hang on..."
    tar -czf "${INM_PROGRAM_NAME}_$(date +'%Y%m%d_%H%M%S').tar.gz" "$INM_BACKUP_DIRECTORY"/*.sql -C "$INM_INSTALLATION_DIRECTORY" . || {
        echo "Failed to create backup"
        exit 1
    }
    rm "$INM_BACKUP_DIRECTORY"/*.sql || {
        echo "Failed to remove SQL files"
        exit 1
    }
    mv ${INM_PROGRAM_NAME}_*.tar.gz "$INM_BACKUP_DIRECTORY" || {
        echo "Failed to move backups"
        exit 1
    }

    cleanup_old_backups
}

# Cleanup old versions
cleanup_old_versions() {
    echo "Cleaning up old update directory versions."
    local update_dirs
    update_dirs=$(find "$INM_BASE_DIRECTORY" -maxdepth 1 -type d -name "$(basename "$INM_INSTALLATION_DIRECTORY")_*" | sort -r | tail -n +$((INM_KEEP_BACKUPS + 1)))

    if [ -n "$update_dirs" ]; then
        echo "$update_dirs" | xargs -r rm -rf || {
            echo "Failed to clean up old versions"
            exit 1
        }
    fi
    rm -Rf "$INM_TEMP_DOWNLOAD_DIRECTORY"
    ls -la "$INM_BASE_DIRECTORY"
}

# Cleanup old backups
cleanup_old_backups() {
    echo "Cleaning up old backups."

    # Find backup files and list them
    local backup_files
    backup_files=$(find "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY" -maxdepth 1 -type f -name "*.tar.gz" | sort -r | tail -n +$((INM_KEEP_BACKUPS + 1)))

    if [ -n "$backup_files" ]; then
        echo "$backup_files" | xargs -r rm -f || {
            echo "Failed to clean up old backups"
            exit 1
        }
    fi
    rm -Rf "$INM_TEMP_DOWNLOAD_DIRECTORY"
    # List remaining files in the backup directory
    ls -la "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY"
}

# Function caller
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
    create-db)
        create_database
        ;;
    cleanup_versions)
        cleanup_old_versions
        ;;
    cleanup_backups)
        cleanup_old_backups
        ;;
    *)
        echo "Unknown parameter $1"
        return 1
        ;;
    esac
}

# Parse command-line options
command=""
force_update=false

parse_options() {

while [[ $# -gt 0 ]]; do
    case $1 in
    --force)
        force_update=true
        shift
        ;;
    clean_install | update | backup | cleanup_versions | cleanup_backups)
        command=$1
        shift
        ;;
    *)
        echo "Unknown option: $1"
        echo -e "\n\n Usage: ./inmanage.sh <update|backup|clean_install|cleanup_versions|cleanup_backups> [--force] \n Full Documentation https://github.com/DrDBanner/inmanage/#readme \n\n"
        exit 1
        ;;
    esac
done
}

check_commands
check_env
parse_options "$@"

if [ -z "$command" ]; then
    echo -e "\n\n Usage: ./inmanage.sh <update|backup|clean_install|cleanup_versions|cleanup_backups> [--force] \n Full Documentation https://github.com/DrDBanner/inmanage/#readme \n\n"
    exit 1
fi

cd "$INM_BASE_DIRECTORY" && function_caller "$command"
