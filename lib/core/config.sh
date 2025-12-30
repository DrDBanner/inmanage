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
    ["INM_CACHE_DIR_MODE"]="" # Empty = auto (775 if group set, else 750).
    ["INM_CACHE_FILE_MODE"]="" # Empty = auto (664 if group set, else 640).
    ["INM_CACHE_SUDO_PROMPT"]="never" # ask|never to enable sudo prompt for cache dir.
    ["INM_CACHE_GLOBAL_RETENTION"]="3" # Keep last N cached releases.
    ["INM_DUMP_OPTIONS"]="--default-character-set=utf8mb4 --no-tablespaces --skip-add-drop-table --quick --single-transaction"
    ["INM_BACKUP_DIRECTORY"]="./.backup"
    ["INM_FORCE_READ_DB_PW"]="N"
    ["INM_ENFORCED_USER"]="www-data"
    ["INM_ENFORCED_GROUP"]="" # Optional group override (defaults to user's primary group).
    ["INM_ENFORCED_SHELL"]="$(command -v bash)"
    ["INM_PHP_EXECUTABLE"]="$(command -v php)"
    ["INM_ARTISAN_STRING"]="\${INM_PHP_EXECUTABLE} \${INM_BASE_DIRECTORY}\${INM_INSTALLATION_DIRECTORY}/artisan"
    ["INM_PROGRAM_NAME"]="InvoiceNinja"
    ["INM_COMPATIBILITY_VERSION"]="5+"
    ["INM_DIR_MODE"]="2775" # Default directory mode for app dirs when fixing perms.
    ["INM_FILE_MODE"]="644" # Default file mode for app files when fixing perms.
    ["INM_ENV_MODE"]="600" # Strict mode for app .env when fixing perms.
    ["INM_KEEP_BACKUPS"]="2"
    ["INM_GH_API_CREDENTIALS"]="" # Format username:password or token:x-oauth.
    ["INM_NOTIFY_ENABLED"]="false" # Enable notifications for non-interactive failures.
    ["INM_NOTIFY_TARGETS"]="email,webhook" # Comma list: email,webhook.
    ["INM_NOTIFY_EMAIL_TO"]="" # Comma-separated recipients.
    ["INM_NOTIFY_EMAIL_FROM"]="" # Override sender address (defaults to app MAIL_FROM_ADDRESS).
    ["INM_NOTIFY_EMAIL_FROM_NAME"]="" # Override sender name (defaults to app MAIL_FROM_NAME).
    ["INM_NOTIFY_LEVEL"]="ERR" # Minimum severity: ERR|WARN|INFO|OK|ALL.
    ["INM_NOTIFY_NONINTERACTIVE_ONLY"]="true" # Only send when no TTY is attached.
    ["INM_NOTIFY_SMTP_TIMEOUT"]="10" # SMTP connect timeout (seconds).
    ["INM_NOTIFY_HOOKS_ENABLED"]="true" # Enable hook notifications.
    ["INM_NOTIFY_HOOKS_FAILURE"]="true" # Notify when hooks fail.
    ["INM_NOTIFY_HOOKS_SUCCESS"]="false" # Notify when hooks succeed.
    ["INM_NOTIFY_HEARTBEAT_ENABLED"]="false" # Enable daily health heartbeat (requires heartbeat cron job).
    ["INM_NOTIFY_HEARTBEAT_TIME"]="06:00" # Heartbeat cron time (HH:MM).
    ["INM_NOTIFY_HEARTBEAT_LEVEL"]="ERR" # Minimum heartbeat severity (ERR|WARN|INFO|OK|ALL).
    ["INM_NOTIFY_HEARTBEAT_INCLUDE"]="" # Optional include filter for heartbeat checks.
    ["INM_NOTIFY_HEARTBEAT_EXCLUDE"]="" # Optional exclude filter for heartbeat checks.
    ["INM_NOTIFY_WEBHOOK_URL"]="" # Webhook target URL.
    ["INM_MIGRATION_BACKUP"]="" # Use LATEST or path to run restore after provision.
    ["INM_CLI_COMPATIBILITY"]="ultron" # Missing => treat as legacy install.
)

# shellcheck disable=SC2034
default_settings_order=(
    "INM_BASE_DIRECTORY"
    "INM_INSTALLATION_DIRECTORY"
    "INM_ENV_FILE"
    "INM_CACHE_LOCAL_DIRECTORY"
    "INM_CACHE_GLOBAL_DIRECTORY"
    "INM_CACHE_DIR_MODE"
    "INM_CACHE_FILE_MODE"
    "INM_CACHE_SUDO_PROMPT"
    "INM_CACHE_GLOBAL_RETENTION"
    "INM_DUMP_OPTIONS"
    "INM_BACKUP_DIRECTORY"
    "INM_FORCE_READ_DB_PW"
    "INM_ENFORCED_USER"
    "INM_ENFORCED_GROUP"
    "INM_ENFORCED_SHELL"
    "INM_PHP_EXECUTABLE"
    "INM_ARTISAN_STRING"
    "INM_PROGRAM_NAME"
    "INM_COMPATIBILITY_VERSION"
    "INM_DIR_MODE"
    "INM_FILE_MODE"
    "INM_ENV_MODE"
    "INM_KEEP_BACKUPS"
    "INM_GH_API_CREDENTIALS"
    "INM_NOTIFY_ENABLED"
    "INM_NOTIFY_TARGETS"
    "INM_NOTIFY_EMAIL_TO"
    "INM_NOTIFY_EMAIL_FROM"
    "INM_NOTIFY_EMAIL_FROM_NAME"
    "INM_NOTIFY_LEVEL"
    "INM_NOTIFY_NONINTERACTIVE_ONLY"
    "INM_NOTIFY_SMTP_TIMEOUT"
    "INM_NOTIFY_HOOKS_ENABLED"
    "INM_NOTIFY_HOOKS_FAILURE"
    "INM_NOTIFY_HOOKS_SUCCESS"
    "INM_NOTIFY_HEARTBEAT_ENABLED"
    "INM_NOTIFY_HEARTBEAT_TIME"
    "INM_NOTIFY_HEARTBEAT_LEVEL"
    "INM_NOTIFY_HEARTBEAT_INCLUDE"
    "INM_NOTIFY_HEARTBEAT_EXCLUDE"
    "INM_NOTIFY_WEBHOOK_URL"
    "INM_MIGRATION_BACKUP"
    "INM_CLI_COMPATIBILITY"
)

# shellcheck disable=SC2034
prompt_order=(
    "INM_BASE_DIRECTORY"
    "INM_INSTALLATION_DIRECTORY"
    "INM_KEEP_BACKUPS"
    "INM_FORCE_READ_DB_PW"
    "INM_ENFORCED_USER"
    "INM_ENFORCED_GROUP"
    "INM_GH_API_CREDENTIALS"
)

# shellcheck disable=SC2034,SC2190
declare -A prompt_texts=(
    ["INM_BASE_DIRECTORY"]="BASE_DIRECTORY: This will contain your Invoice Ninja app directory (next step). It's not webserver's docroot. Define your desired location or keep."
    ["INM_INSTALLATION_DIRECTORY"]="INSTALLATION_DIRECTORY: Invoice Ninja App directory. The web-server usually serves from <INSTALLATION_DIRECTORY>/public. Define your desired location or keep."
    ["INM_DUMP_OPTIONS"]="DUMP_OPTIONS: Modify database dump options: In doubt, keep defaults."
    ["INM_BACKUP_DIRECTORY"]="BACKUP_DIRECTORY: Define your desired location or keep."
    ["INM_FORCE_READ_DB_PW"]="FORCE_READ_DB_PW: Include DB password in CLI? (Y): Convenient, but may expose the password to other server users during runtime. (N): Assumes a secure .my.cnf file with credentials to avoid exposure."
    ["INM_ENFORCED_USER"]="ENFORCED_USER: Correct setting helps to mitigate permission issues. Usually the webserver user. On shared hosting often your current user."
    ["INM_ENFORCED_SHELL"]="ENFORCED_SHELL: In doubt, keep as is."
    ["INM_PHP_EXECUTABLE"]="PHP_EXECUTABLE: In doubt, keep as is."
    ["INM_KEEP_BACKUPS"]="KEEP_BACKUPS: Backup retention? Set to 2 to keep 2 backups in the past at a time. Ensure enough disk space and keep the backup frequency in mind."
    ["INM_GH_API_CREDENTIALS"]="GitHub API credentials may be required on shared hosting. Use the format username:password or token:x-oauth. If provided, all curl commands will use these credentials;"
)

# shellcheck disable=SC2034,SC2190
declare -A default_inline_comments=(
    ["INM_CACHE_DIR_MODE"]="Empty = auto (775 if group set, else 750)."
    ["INM_CACHE_FILE_MODE"]="Empty = auto (664 if group set, else 640)."
    ["INM_CACHE_SUDO_PROMPT"]="ask|never to enable sudo prompt for cache dir."
    ["INM_CACHE_GLOBAL_RETENTION"]="Keep last N cached releases."
    ["INM_ENFORCED_GROUP"]="Optional group override (defaults to user's primary group)."
    ["INM_DIR_MODE"]="Default directory mode for app dirs when fixing perms."
    ["INM_FILE_MODE"]="Default file mode for app files when fixing perms."
    ["INM_ENV_MODE"]="Strict mode for app .env when fixing perms."
    ["INM_GH_API_CREDENTIALS"]="Format username:password or token:x-oauth."
    ["INM_NOTIFY_ENABLED"]="Enable notifications for non-interactive failures."
    ["INM_NOTIFY_TARGETS"]="Comma list: email,webhook."
    ["INM_NOTIFY_EMAIL_TO"]="Comma-separated recipients."
    ["INM_NOTIFY_EMAIL_FROM"]="Override sender address (defaults to app MAIL_FROM_ADDRESS)."
    ["INM_NOTIFY_EMAIL_FROM_NAME"]="Override sender name (defaults to app MAIL_FROM_NAME)."
    ["INM_NOTIFY_LEVEL"]="Minimum severity: ERR|WARN|INFO|OK|ALL."
    ["INM_NOTIFY_NONINTERACTIVE_ONLY"]="Only send when no TTY is attached."
    ["INM_NOTIFY_SMTP_TIMEOUT"]="SMTP connect timeout (seconds)."
    ["INM_NOTIFY_HOOKS_ENABLED"]="Enable hook notifications."
    ["INM_NOTIFY_HOOKS_FAILURE"]="Notify when hooks fail."
    ["INM_NOTIFY_HOOKS_SUCCESS"]="Notify when hooks succeed."
    ["INM_NOTIFY_HEARTBEAT_ENABLED"]="Enable daily health heartbeat (requires heartbeat cron job)."
    ["INM_NOTIFY_HEARTBEAT_TIME"]="Heartbeat cron time (HH:MM)."
    ["INM_NOTIFY_HEARTBEAT_LEVEL"]="Minimum heartbeat severity (ERR|WARN|INFO|OK|ALL)."
    ["INM_NOTIFY_HEARTBEAT_INCLUDE"]="Optional include filter for heartbeat checks."
    ["INM_NOTIFY_HEARTBEAT_EXCLUDE"]="Optional exclude filter for heartbeat checks."
    ["INM_NOTIFY_WEBHOOK_URL"]="Webhook target URL."
    ["INM_MIGRATION_BACKUP"]="Use LATEST or path to run restore after provision."
    ["INM_CLI_COMPATIBILITY"]="Missing => treat as legacy install."
)
