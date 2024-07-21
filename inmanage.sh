#!/bin/bash
set -e

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

if [ ! -f ".inmanage/.env.inmanage" ]; then
    echo ".inmanage/.env.inmanage configuration file for this script not found. Attempting to create it..."

    # Temporarily create the file to check if it's possible
    if touch ".inmanage/.env.inmanage"; then
        echo "File creation successful. Proceeding with configuration..."

        # Query for configuration
        echo -e "\n\n Just press [ENTER] to accept defaults. \n\n"
        INM_BASE_DIRECTORY=$(prompt "INM_BASE_DIRECTORY" "$PWD/" "Which directory contains your IN installation folder? Must have a trailing slash.")
        INM_INSTALLATION_DIRECTORY=$(prompt "INM_INSTALLATION_DIRECTORY" "./invoiceninja" "What is the installation directory name? Must be relative from $INM_BASE_DIRECTORY and can start with a . dot.")
        INM_ENV_FILE="$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/.env"
        INM_TEMP_DOWNLOAD_DIRECTORY="./._in_tempDownload"
        INM_BACKUP_DIRECTORY=$(prompt "INM_BACKUP_DIRECTORY" "./_in_backups" "Where shall backups go?")
        INM_FORCE_READ_DB_PW=$(prompt "INM_FORCE_READ_DB_PW" "N" "Include database password in backup command? If Y we read it from Invoice Ninja installation, but it's a security concern and may be visible for other server users while the task is running. If N the script assumes you have a secure and working .my.cnf file with your DB credentials. (Y/N)")
        INM_ENFORCED_USER=$(prompt "INM_ENFORCED_USER" "web" "The user running the script? Should be the webserver user in most cases. Check twice if this value is set correct according to your webserver setup.")
        INM_ENFORCED_SHELL=$(prompt "INM_ENFORCED_SHELL" "$(command -v bash)" "Which shell should be used? In doubt, keep as is.")
        INM_PHP_EXECUTABLE=$(prompt "INM_PHP_EXECUTABLE" "$(command -v php)" "Path to the PHP executable? In doubt, keep as is.")
        INM_ARTISAN_STRING="$INM_PHP_EXECUTABLE $INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/artisan"
        INM_PROGRAM_NAME="InvoiceNinja"
        INM_COMPATIBILITY_VERSION="5+"
        INM_KEEP_BACKUPS=$(prompt "INM_KEEP_BACKUPS" "2" "How many backup files and update iterations to keep? If you keep 7 and backup on a daily basis you have 7 snapshots available.")

        # Save configuration to .env.inmanage
        cat <<EOL >.inmanage/.env.inmanage
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

        echo ".env.inmanage has been created and configured."

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

        echo "A symlink to this script has been created in the base directory."
    else
        echo "Error: Could not create .inmanage/.env.inmanage. Aborting configuration."
        exit 1
    fi
fi

source .inmanage/.env.inmanage


# Check required commands
check_commands() {
    local commands=("curl" "tar" "cp" "mv" "mkdir" "chown" "find" "rm" "mysqldump" "grep" "xargs" "php" "read" "source" "touch")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: Command '$cmd' is not available. Please install it and try again."
            exit 1
        fi
    done
}

# Ensure script runs as INM_ENFORCED_USER
if [ "$(whoami)" != "$INM_ENFORCED_USER" ]; then
    INM_SCRIPT_PATH=$(realpath "$0")
    echo "Switching to user '$INM_ENFORCED_USER'."
    exec sudo -u "$INM_ENFORCED_USER" "$INM_ENFORCED_SHELL" -c "cd '$(pwd)' && \"$INM_ENFORCED_SHELL\" \"$INM_SCRIPT_PATH\" \"$@\""
    exit 0
fi

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

# Run update
run_update() {
    local installed_version latest_version

    installed_version=$(get_installed_version)
    latest_version=$(get_latest_version)

   if [ "$installed_version" == "$latest_version" ] && [ "$force_update" != true ]; then
        echo -n "Already up-to-date. Proceed with update? (yes/no): "
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
    tar -xf invoiceninja.tar -C "$INM_INSTALLATION_DIRECTORY" || {
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

    # List remaining files in the backup directory
    ls -la "$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY"
}



# Function caller
function_caller() {
    case "$1" in
    update)
        run_update
        ;;
    backup)
        run_backup
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
force_update=false
while [[ $# -gt 0 ]]; do
    case $1 in
    --force)
        force_update=true
        shift
        ;;
    update | backup | cleanup_versions | cleanup_backups)
        command=$1
        shift
        ;;
    *)
        echo -e "\n\n Usage: ./inmanage.sh <update|backup|cleanup_versions|cleanup_backups> [--force] \n\n"
        exit 1
        ;;
    esac
done

if [ -z "$command" ]; then
    echo -e "\n\n Usage: ./inmanage.sh <update|backup|cleanup_versions|cleanup_backups> [--force] \n\n"
    exit 1
fi

check_commands

cd "$INM_BASE_DIRECTORY" && function_caller "$command"
