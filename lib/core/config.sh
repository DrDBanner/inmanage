#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__CORE_CONFIG_LOADED:-} ]] && return
__CORE_CONFIG_LOADED=1

# ---------------------------------------------------------------------
# default_settings/prompt definitions
#
# Houses config defaults, prompt ordering/texts. Keeps legacy behavior
# intact while allowing reuse across modules.
# ---------------------------------------------------------------------
# shellcheck disable=SC2034,SC2190
declare -A default_settings=(
    ["INM_BASE_DIRECTORY"]="$PWD/"
    ["INM_INSTALLATION_DIRECTORY"]="./invoiceninja"
    ["INM_ENV_FILE"]="\${INM_BASE_DIRECTORY}\${INM_INSTALLATION_DIRECTORY}/.env"
    ["INM_CACHE_LOCAL_DIRECTORY"]="./.cache"
    ["INM_CACHE_GLOBAL_DIRECTORY"]="\${HOME}/.inmanage/cache"
    ["INM_CACHE_SUDO_PROMPT"]="never" # ask|never to enable sudo prompt for cache dir.
    ["INM_CACHE_GLOBAL_RETENTION"]="3" # Keep last N cached releases.
    ["INM_DUMP_OPTIONS"]="--default-character-set=utf8mb4 --no-tablespaces --skip-add-drop-table --quick --single-transaction"
    ["INM_BACKUP_DIRECTORY"]="./.backups"
    ["INM_FORCE_READ_DB_PW"]="N"
    ["INM_ENFORCED_USER"]="www-data"
    ["INM_ENFORCED_SHELL"]="$(command -v bash)"
    ["INM_PHP_EXECUTABLE"]="$(command -v php)"
    ["INM_ARTISAN_STRING"]="\${INM_PHP_EXECUTABLE} \${INM_BASE_DIRECTORY}\${INM_INSTALLATION_DIRECTORY}/artisan"
    ["INM_PROGRAM_NAME"]="InvoiceNinja"
    ["INM_COMPATIBILITY_VERSION"]="5+"
    ["INM_KEEP_BACKUPS"]="2"
    ["INM_GH_API_CREDENTIALS"]="" # Format username:password or token:x-oauth.
    ["INM_MIGRATION_BACKUP"]="" # Use LATEST or path to run restore after provision.
    ["INM_CLI_COMPATIBILITY"]="new" # Missing => treat as legacy install.
)

# shellcheck disable=SC2034
prompt_order=(
    "INM_BASE_DIRECTORY"
    "INM_INSTALLATION_DIRECTORY"
    "INM_KEEP_BACKUPS"
    "INM_FORCE_READ_DB_PW"
    "INM_ENFORCED_USER"
    "INM_GH_API_CREDENTIALS"
)

# shellcheck disable=SC2034,SC2190
declare -A prompt_texts=(
    ["INM_BASE_DIRECTORY"]="BASE_DIRECTORY: This will contain your Invoice Ninja app directory (next step). It's not webserver's docroot. Define your desired location or keep."
    ["INM_INSTALLATION_DIRECTORY"]="INSTALLATION_DIRECTORY: Invoice Ninja App directory. The web-server usually serves from <INSTALLATION_DIRECTORY>/public. Define your desired location or keep."
    ["INM_DUMP_OPTIONS"]="DUMP_OPTIONS: Modify database dump options: In doubt, keep defaults."
    ["INM_BACKUP_DIRECTORY"]="BACKUP_DIRECTORY: Define your desired location or keep."
    ["INM_FORCE_READ_DB_PW"]="FORCE_READ_DB_PW: Include DB password in CLI? (Y): Convenient, but may expose the password to other server users during runtime. (N): Assumes a secure .my.cnf file with credentials to avoid exposure."
    ["INM_ENFORCED_USER"]="ENFORCED_USER: Correct setting helps to mitigate permission issues. Usually the webserver user. On shared hosting often your current user. If current is true, you can leave this empty."
    ["INM_ENFORCED_SHELL"]="ENFORCED_SHELL: In doubt, keep as is."
    ["INM_PHP_EXECUTABLE"]="PHP_EXECUTABLE: In doubt, keep as is."
    ["INM_KEEP_BACKUPS"]="KEEP_BACKUPS: Backup retention? Set to 2 to keep 2 backups in the past at a time. Ensure enough disk space and keep the backup frequency in mind."
    ["INM_GH_API_CREDENTIALS"]="GitHub API credentials may be required on shared hosting. Use the format username:password or token:x-oauth. If provided, all curl commands will use these credentials;"
)
