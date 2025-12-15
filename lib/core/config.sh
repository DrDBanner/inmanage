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
    ["INM_CACHE_GLOBAL_RETENTION"]="3"
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
    ["INM_GH_API_CREDENTIALS"]="" #format username:password or token:x-oauth.
    ["INM_MIGRATION_BACKUP"]=""
)

# shellcheck disable=SC2034
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

# shellcheck disable=SC2034,SC2190
declare -A prompt_texts=(
    ["INM_BASE_DIRECTORY"]="Base directory location? This will contain your Invoice Ninja app directory (next step). Not the web docroot."
    ["INM_INSTALLATION_DIRECTORY"]="Invoice Ninja app directory (relative to \$INM_BASE_DIRECTORY or absolute). The web server usually serves from <app>/public."
    ["INM_DUMP_OPTIONS"]="Modify database dump options: In doubt, keep defaults."
    ["INM_BACKUP_DIRECTORY"]="Backup Directory?"
    ["INM_FORCE_READ_DB_PW"]="Include DB password in CLI? (Y): Convenient, but may expose the password to other server users during runtime. (N): Assumes a secure .my.cnf file with credentials to avoid exposure."
    ["INM_ENFORCED_USER"]="Script user? Usually the webserver user. Ensure it matches your webserver setup."
    ["INM_ENFORCED_SHELL"]="Which shell should be used? In doubt, keep as is."
    ["INM_PHP_EXECUTABLE"]="Path to the PHP executable? In doubt, keep as is."
    ["INM_KEEP_BACKUPS"]="Backup retention? Set to 2 for daily backups to keep 2 snapshots. Ensure enough disk space."
    ["INM_GH_API_CREDENTIALS"]="GitHub API credentials may be required on shared hosting. Use the format username:password or token:x-oauth. If provided, all curl commands will use these credentials;"
)
