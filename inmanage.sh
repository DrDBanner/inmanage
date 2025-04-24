#!/bin/bash
set -e

## Self configuration
INM_SELF_ENV_FILE=".inmanage/.env.inmanage"
INM_PROVISION_ENV_FILE=".inmanage/.env.provision"

## Globals
CURL_AUTH_FLAG="" 

# Declare an associative array for default settings and their corresponding prompt texts. Will be used to create .
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

# Declare an associative array for the corresponding prompt texts
declare -A prompt_texts=(
    ["INM_BASE_DIRECTORY"]="Which directory contains your IN installation folder? Must have a trailing slash."
    ["INM_INSTALLATION_DIRECTORY"]="What is the installation directory name? Must be relative from \$INM_BASE_DIRECTORY and can start with a . dot."
    ["INM_DUMP_OPTIONS"]="Add options to your dump command. In doubt, keep defaults."
    ["INM_BACKUP_DIRECTORY"]="Where shall backups go?"
    ["INM_FORCE_READ_DB_PW"]="Include DB password in backup? (Y): May expose the password to other server users during runtime. (N): Assumes a secure .my.cnf file with credentials to avoid exposure."
    ["INM_ENFORCED_USER"]="Script user? Usually the webserver user. Ensure it matches your webserver setup."
    ["INM_ENFORCED_SHELL"]="Which shell should be used? In doubt, keep as is."
    ["INM_PHP_EXECUTABLE"]="Path to the PHP executable? In doubt, keep as is."
    ["INM_KEEP_BACKUPS"]="Backup retention? Set to 7 for daily backups to keep 7 snapshots. Ensure enough disk space."
    ["INM_GH_API_CREDENTIALS"]="GitHub API credentials may be required on shared hosting. Use the format username:password or token:x-oauth. If provided, all curl commands will use these credentials;"
)

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
    check_missing_settings
    check_provision_file
  fi
}


check_gh_credentials() {
    source "$INM_SELF_ENV_FILE"
    # Check for GH Credentials
    if [[ -n "$INM_GH_API_CREDENTIALS" && "$INM_GH_API_CREDENTIALS" == *:* ]]; then
        CURL_AUTH_FLAG="-u $INM_GH_API_CREDENTIALS"
        echo "GH Authentication detected. Curl commands will include credentials."
    else
        CURL_AUTH_FLAG=""
        # echo "$INM_GH_API_CREDENTIALS"
        echo "Proceeding without GH credentials authentication. If update fails, try to add credentials."
    fi
}

# Create config file and symlink in base directory
create_own_config() {
    if touch "$INM_SELF_ENV_FILE"; then
        echo "Write Permissions OK. Proceeding with configuration..."
        rm $INM_SELF_ENV_FILE

        echo -e "\n\n Just press [ENTER] to accept defaults. \n\n"

        # Loop through default settings and prompt user for input, allowing them to override
        for key in "${!default_settings[@]}"; do
            value=${default_settings[$key]}
            prompt_text=${prompt_texts[$key]:-"Provide value for $key:"}
            default_settings[$key]=$(prompt "$key" "$value" "$prompt_text")
        done

        # Save configuration to .env.inmanage
        for key in "${!default_settings[@]}"; do
            echo "$key=\"${default_settings[$key]}\"" >> "$INM_SELF_ENV_FILE"
        done

        echo "$INM_SELF_ENV_FILE has been created and configured."
        source "$INM_SELF_ENV_FILE"
        
        # Defined?
        if [ -z "$INM_BASE_DIRECTORY" ]; then
            echo "Error: 'INM_BASE_DIRECTORY' variable is empty. Stopping script. File an issue on github."
            exit 1
        fi
        
        # Handle symlink
        target="$INM_BASE_DIRECTORY.inmanage/inmanage.sh"
        link="$INM_BASE_DIRECTORY/inmanage.sh"

        # Debug
        # echo "DEBUG: link='$link', target='$target'"

        # Check if the link exists
        if [ -L "$link" ]; then
            # Check if it points to the correct target
            current_target=$(readlink "$link")
            if [ "$current_target" == "$target" ]; then
                echo "The symlink is correct."
            else
                echo "The symlink is incorrect. Updating..."
                ln -sf "$target" "$link"
            fi
        else
            echo "The symlink does not exist. Creating..."
            ln -s "$target" "$link"
        fi


        # Download .env.example for provisioning
        env_example_file="$INM_BASE_DIRECTORY.inmanage/.env.example"
        echo "Downloading .env.example for provisioning"
        curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" -o "$env_example_file" || {
            echo "Failed to download .env.example for seeding"
            exit 1
        }

        # Modify the downloaded file
        if [ -f "$env_example_file" ]; then
            sed -i '/^DB_PORT=/a DB_ELEVATED_USERNAME=\nDB_ELEVATED_PASSWORD=' "$env_example_file"
        fi

        # Source the configuration file and check for provisioning
        source "$INM_SELF_ENV_FILE"
        check_provision_file
    else
        echo "Error: Could not create $INM_SELF_ENV_FILE. Aborting configuration."
        exit 1
    fi
}

# Check if any new settings are missing from the environment file
check_missing_settings() {
    updated=0

    # Loop through default settings and check if they exist in the env file
    for key in "${!default_settings[@]}"; do
        if ! grep -q "^$key=" "$INM_SELF_ENV_FILE"; then
            echo "$key not found in $INM_SELF_ENV_FILE. Adding with default value '${default_settings[$key]}'."
            echo "$key=\"${default_settings[$key]}\"" >> "$INM_SELF_ENV_FILE"
            updated=1
        fi
    done

    # Reload the environment file if any settings were updated
    if [ "$updated" -eq 1 ]; then
        echo "Updated $INM_SELF_ENV_FILE with missing settings. Reloading..."
        source "$INM_SELF_ENV_FILE"
    else
        echo "All settings are present in $INM_SELF_ENV_FILE."
    fi
}

# Check required commands
check_commands() {
    local commands=("curl" "wc" "tar" "cp" "mv" "mkdir" "chown" "find" "rm" "mysqldump" "mysql" "grep" "xargs" "php" "read" "source" "touch" "sed" "sudo" "tee")
    local missing_commands=()

    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        echo "Error: The following commands are not available:"
        for missing in "${missing_commands[@]}"; do
            echo "  - $missing"
        done
        exit 1
    else
        echo "All required commands are available."
    fi
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
    version=$(curl -s ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} https://api.github.com/repos/invoiceninja/invoiceninja/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//') || {
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

    # Temp File
    temp_file="invoiceninja_temp.tar"

    if curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} -w "%{http_code}" "https://github.com/invoiceninja/invoiceninja/releases/download/v$app_version/invoiceninja.tar" -o "$temp_file" | grep -q "200"; then
        # Check size
        if [ $(wc -c < "$temp_file") -gt 1048576 ]; then  # < 1MB in size should be good
            mv "$temp_file" "invoiceninja.tar"
            echo "Download successful."
        else
            echo "Download failed: File is too small. Please check network."
            rm "$temp_file"
        exit 1
    fi
    else
        echo "Download failed: HTTP-Statuscode not 200. Please check network. Maybe you need Gitgub credentials."
        rm "$temp_file"
    exit 1
    fi
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
    $INM_ARTISAN_STRING migrate:fresh --seed --force || {
        echo "Failed to run artisan migrate"
        exit 1
    }
    $INM_ARTISAN_STRING ninja:create-account --email=admin@admin.com --password=admin && echo -e "\n\nLogin: $APP_URL Username: admin@admin.com Password: admin" || {
        echo "Standard user creation failed"
        exit 1
    }
        echo -e "\n\nSetup Complete!\n\n\
Open your browser at $APP_URL to access the application.\n\
The database and user are configured.\n\n\
IT'S A GOOD TIME TO MAKE YOUR FIRST BACKUP NOW!!\n\n\
Cronjob Setup:\n\
Add this for scheduled tasks:\n\
* * * * * $INM_ENFORCED_USER $INM_ARTISAN_STRING schedule:run >> /dev/null 2>&1\n\n\
Scheduled Backup:\n\
To schedule a backup, add this:\n\
* 3 * * * $INM_ENFORCED_USER $INM_ENFORCED_SHELL -c \"$INM_BASE_DIRECTORY./inmanage.sh backup\" >> /dev/null 2>&1\n\n"

    else
        echo -e "\n\nSetup Complete!\n\n\
Open your browser at your configured address https://your.url/setup now to carry on with database setup.\n\n\
IT'S A GOOD TIME TO MAKE YOUR FIRST BACKUP NOW!!\n\n\
Cronjob Setup:\n\
Add this for scheduled tasks:\n\
* * * * * $INM_ENFORCED_USER $INM_ARTISAN_STRING schedule:run >> /dev/null 2>&1\n\n\
Scheduled Backup:\n\
To schedule a backup, add this:\n\
* 3 * * * $INM_ENFORCED_USER $INM_ENFORCED_SHELL -c \"$INM_BASE_DIRECTORY./inmanage.sh backup\" >> /dev/null 2>&1\n\n"
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
    if [ -d "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/" ]; then
        cp -R "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/." "$INM_INSTALLATION_DIRECTORY/public/storage/" || {
            echo "Failed to copy storage from $INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/."
        }
        else
            echo "Directory does not exist: $INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/storage/"
            echo "This may be normal if this is an initial installation, or if your storage is located somewhere different. You may need to copy data manually."
    fi
    
   
    # Copy regular .ini files if they exist
    if compgen -G "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/"*.ini > /dev/null; then
        cp -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/"*.ini "$INM_INSTALLATION_DIRECTORY/public/"
    fi
    
    # Copy hidden .ini files if they exist
    if compgen -G "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/".*.ini > /dev/null; then
        cp -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/".*.ini "$INM_INSTALLATION_DIRECTORY/public/"
    fi
    
    # Copy .htaccess if it exists
    if [[ -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/.htaccess" ]]; then
        cp -f "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY/public/.htaccess" "$INM_INSTALLATION_DIRECTORY/public/"
    fi


    mv "$INM_BASE_DIRECTORY$INM_INSTALLATION_DIRECTORY" "$INM_BASE_DIRECTORY${INM_INSTALLATION_DIRECTORY}_$(date +'%Y%m%d_%H%M%S')" || {
        echo "Failed to rename old installation"
        exit 1
    }
    
    chmod 600 "$INM_INSTALLATION_DIRECTORY/.env" || {
        echo "Failed to chmod 600 .env file. Please check what's wrong."
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
    if [ -f "$old_version_dir/storage/framework/down" ]; then
        rm "$old_version_dir/storage/framework/down" || {
            echo "Failed to remove 'Maintenance' file from $old_version_dir/storage/framework/"
            exit 1
        }
        echo "'Maintenanace' file removed from $old_version_dir/storage/framework/."
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
    $INM_ARTISAN_STRING ninja:design-update || {
        echo "Failed to run design-update"
        exit 1
    }
    $INM_ARTISAN_STRING up || {
        echo "Failed to run artisan up"
        exit 1
    }
    # Do if Snappdf set in .env file
    source "$INM_ENV_FILE"

    if [ "$PDF_GENERATOR" = "snappdf" ]; then
    echo "Snappdf configuration detected. Updating binaries. Downloading ungoogled chrome."
    cd "${INM_BASE_DIRECTORY}${INM_INSTALLATION_DIRECTORY}"
    
    if [ ! -x "./vendor/bin/snappdf" ]; then
        echo "The file ./vendor/bin/snappdf is not executable. Adding executable flag."
        chmod +x ./vendor/bin/snappdf
    fi
    echo "Downloading snappdf"
    $INM_PHP_EXECUTABLE ./vendor/bin/snappdf download
else
    echo "Skipping snappdf config."
fi


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

    # Use CLI Password mode or my.cnf
    if [ "$INM_FORCE_READ_DB_PW" == "Y" ]; then
        echo -n "Dumping database..."
        mysqldump $INM_DUMP_OPTIONS -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" | tee "${DB_DATABASE}_$(date +'%Y%m%d_%H%M%S').sql" > /dev/null || {
            echo "Failed to dump database"
            exit 1
        }
        echo " Done."
    else
        echo "Using .my.cnf file for database selection and access"
        echo -n "Dumping database..."
        mysqldump $INM_DUMP_OPTIONS -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" "$DB_DATABASE" | tee "${DB_DATABASE}_$(date +'%Y%m%d_%H%M%S').sql" > /dev/null || {
            echo "Failed to dump database"
            exit 1
        }
        echo " Done."
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
check_gh_credentials
parse_options "$@"

if [ -z "$command" ]; then
    echo -e "\n\n Usage: ./inmanage.sh <update|backup|clean_install|cleanup_versions|cleanup_backups> [--force] \n Full Documentation https://github.com/DrDBanner/inmanage/#readme \n\n"
    exit 1
fi

cd "$INM_BASE_DIRECTORY" && function_caller "$command"
