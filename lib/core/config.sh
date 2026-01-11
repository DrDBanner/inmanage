#!/usr/bin/env bash

# ---------------------------------------------------------------------
# Core module: config.sh
# Scope: default settings, prompt order/texts, config metadata.
# Avoid: runtime actions; services/helpers apply behavior.
# Provides: default_settings + config key metadata.
# ---------------------------------------------------------------------

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
    ["INM_BACKUP_DIR_MODE"]="" # Optional override for backup dir mode (empty=use INM_DIR_MODE).
    ["INM_HISTORY_LOG_FILE"]="\${INM_BASE_DIRECTORY}/.inmanage/history.log"
    ["INM_HISTORY_LOG_MAX_SIZE"]="512K"
    ["INM_HISTORY_LOG_ROTATE"]="5"
    ["INM_FORCE_READ_DB_PW"]="N"
    ["INM_ENFORCED_USER"]="www-data"
    ["INM_ENFORCED_GROUP"]="" # Optional group override (defaults to user's primary group).
    ["INM_ENFORCED_SHELL"]="$(command -v bash)"
    ["INM_PHP_EXECUTABLE"]="$(command -v php)"
    ["INM_ARTISAN_STRING"]="\${INM_PHP_EXECUTABLE} \${INM_BASE_DIRECTORY}\${INM_INSTALLATION_DIRECTORY}/artisan"
    ["INM_PROGRAM_NAME"]="InvoiceNinja"
    ["INM_COMPATIBILITY_VERSION"]="5+"
    ["INM_DIR_MODE"]="2750" # Default directory mode for app dirs when fixing perms.
    ["INM_FILE_MODE"]="644" # Default file mode for app files when fixing perms.
    ["INM_ENV_MODE"]="600" # Strict mode for app .env when fixing perms.
    ["INM_CLI_ENV_MODE"]="600" # Strict mode for CLI config when fixing perms.
    ["INM_KEEP_BACKUPS"]="2"
    ["INM_AUTO_UPDATE_CHECK"]="true" # Show startup update notice for app + CLI (uses last health check results).
    ["INM_GH_API_CREDENTIALS"]="" # Format username:password or token:x-oauth.
    ["INM_NOTIFY_ENABLED"]="false" # Enable notifications for non-interactive failures.
    ["INM_NOTIFY_TARGETS"]="email,webhook" # Comma list: email,webhook.
    ["INM_NOTIFY_EMAIL_TO"]="" # Comma-separated recipients.
    ["INM_NOTIFY_EMAIL_FROM"]="" # Override sender address (defaults to app MAIL_FROM_ADDRESS).
    ["INM_NOTIFY_EMAIL_FROM_NAME"]="Heartbeat | Invoice Ninja" # Override sender name (defaults to app MAIL_FROM_NAME).
    ["INM_NOTIFY_LEVEL"]="ERR" # Minimum severity: ERR|WARN|INFO|OK|ALL.
    ["INM_NOTIFY_NONINTERACTIVE_ONLY"]="true" # Only send when no TTY is attached.
    ["INM_NOTIFY_SMTP_TIMEOUT"]="10" # SMTP connect timeout (seconds).
    ["INM_NOTIFY_HOOKS_ENABLED"]="true" # Enable hook notifications.
    ["INM_NOTIFY_HOOKS_FAILURE"]="true" # Notify when hooks fail.
    ["INM_NOTIFY_HOOKS_SUCCESS"]="false" # Notify when hooks succeed.
    ["INM_NOTIFY_HEARTBEAT_ENABLED"]="false" # Enable daily health heartbeat (requires heartbeat cron job).
    ["INM_NOTIFY_HEARTBEAT_TIME"]="06:00" # Heartbeat cron time (HH:MM).
    ["INM_NOTIFY_HEARTBEAT_LEVEL"]="ERR" # Minimum heartbeat severity (ERR|WARN|INFO|OK|ALL).
    ["INM_NOTIFY_HEARTBEAT_FORMAT"]="compact" # Heartbeat summary format (compact|full|failed).
    ["INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL"]="auto" # Legacy heartbeat detail fallback (auto=use INM_NOTIFY_HEARTBEAT_LEVEL).
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
    "INM_BACKUP_DIR_MODE"
    "INM_HISTORY_LOG_FILE"
    "INM_HISTORY_LOG_MAX_SIZE"
    "INM_HISTORY_LOG_ROTATE"
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
    "INM_CLI_ENV_MODE"
    "INM_KEEP_BACKUPS"
    "INM_AUTO_UPDATE_CHECK"
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
    "INM_NOTIFY_HEARTBEAT_FORMAT"
    "INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL"
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
    ["INM_BASE_DIRECTORY"]="BASE_DIRECTORY: This will contain your Invoice Ninja app directory (next step). It's not the webserver docroot. Define your desired location or keep."
    ["INM_INSTALLATION_DIRECTORY"]="INSTALLATION_DIRECTORY: Invoice Ninja app directory. The web server usually serves from <INSTALLATION_DIRECTORY>/public. Define your desired location or keep."
    ["INM_ENV_FILE"]="ENV_FILE: Path to the Invoice Ninja .env file. Usually keep default."
    ["INM_CACHE_LOCAL_DIRECTORY"]="CACHE_LOCAL_DIRECTORY: Local (project) cache directory."
    ["INM_CACHE_GLOBAL_DIRECTORY"]="CACHE_GLOBAL_DIRECTORY: Shared/global cache directory."
    ["INM_CACHE_DIR_MODE"]="CACHE_DIR_MODE: Permission mode for cache directories (empty=auto)."
    ["INM_CACHE_FILE_MODE"]="CACHE_FILE_MODE: Permission mode for cache files (empty=auto)."
    ["INM_CACHE_SUDO_PROMPT"]="CACHE_SUDO_PROMPT: ask or never to use sudo for cache dirs."
    ["INM_CACHE_GLOBAL_RETENTION"]="CACHE_GLOBAL_RETENTION: Keep last N cached releases."
    ["INM_DUMP_OPTIONS"]="DUMP_OPTIONS: Modify database dump options. In doubt, keep defaults."
    ["INM_BACKUP_DIRECTORY"]="BACKUP_DIRECTORY: Define your desired location or keep."
    ["INM_BACKUP_DIR_MODE"]="BACKUP_DIR_MODE: Optional mode for the backup directory (empty=use DIR_MODE)."
    ["INM_HISTORY_LOG_FILE"]="HISTORY_LOG_FILE: Path to the history log file."
    ["INM_HISTORY_LOG_MAX_SIZE"]="HISTORY_LOG_MAX_SIZE: Rotate when log exceeds this size (bytes, K, M, G)."
    ["INM_HISTORY_LOG_ROTATE"]="HISTORY_LOG_ROTATE: Number of rotated history logs to keep."
    ["INM_FORCE_READ_DB_PW"]="FORCE_READ_DB_PW: Include DB password in CLI? (Y) convenient but exposes the password during runtime. (N) assumes a secure .my.cnf."
    ["INM_ENFORCED_USER"]="ENFORCED_USER: Correct setting helps mitigate permission issues. Usually the webserver user. On shared hosting often your current user."
    ["INM_ENFORCED_GROUP"]="ENFORCED_GROUP: Optional group override for ownership."
    ["INM_ENFORCED_SHELL"]="ENFORCED_SHELL: Shell used for cron and hooks. In doubt, keep as is."
    ["INM_PHP_EXECUTABLE"]="PHP_EXECUTABLE: Path to php binary. In doubt, keep as is."
    ["INM_ARTISAN_STRING"]="ARTISAN_STRING: Command used to call artisan."
    ["INM_PROGRAM_NAME"]="PROGRAM_NAME: Label used for backups and outputs."
    ["INM_COMPATIBILITY_VERSION"]="COMPATIBILITY_VERSION: Invoice Ninja compatibility hint."
    ["INM_DIR_MODE"]="DIR_MODE: Default directory mode when fixing perms."
    ["INM_FILE_MODE"]="FILE_MODE: Default file mode when fixing perms."
    ["INM_ENV_MODE"]="ENV_MODE: Mode for app .env when fixing perms."
    ["INM_CLI_ENV_MODE"]="CLI_ENV_MODE: Mode for CLI .env.inmanage when fixing perms."
    ["INM_KEEP_BACKUPS"]="KEEP_BACKUPS: Backup retention. Set to 2 to keep 2 backups in the past at a time."
    ["INM_AUTO_UPDATE_CHECK"]="AUTO_UPDATE_CHECK: Show stored app + CLI update notice on CLI start (from last health)."
    ["INM_GH_API_CREDENTIALS"]="GH_API_CREDENTIALS: GitHub API credentials (username:password or token:x-oauth)."
    ["INM_NOTIFY_ENABLED"]="NOTIFY_ENABLED: Enable notifications for non-interactive failures."
    ["INM_NOTIFY_TARGETS"]="NOTIFY_TARGETS: Comma list of targets (email,webhook)."
    ["INM_NOTIFY_EMAIL_TO"]="NOTIFY_EMAIL_TO: Comma-separated recipients."
    ["INM_NOTIFY_EMAIL_FROM"]="NOTIFY_EMAIL_FROM: Override sender address."
    ["INM_NOTIFY_EMAIL_FROM_NAME"]="NOTIFY_EMAIL_FROM_NAME: Override sender name."
    ["INM_NOTIFY_LEVEL"]="NOTIFY_LEVEL: Minimum severity (ERR|WARN|INFO|OK|ALL)."
    ["INM_NOTIFY_NONINTERACTIVE_ONLY"]="NOTIFY_NONINTERACTIVE_ONLY: Only send when no TTY is attached."
    ["INM_NOTIFY_SMTP_TIMEOUT"]="NOTIFY_SMTP_TIMEOUT: SMTP connect timeout (seconds)."
    ["INM_NOTIFY_HOOKS_ENABLED"]="NOTIFY_HOOKS_ENABLED: Enable hook notifications."
    ["INM_NOTIFY_HOOKS_FAILURE"]="NOTIFY_HOOKS_FAILURE: Notify when hooks fail."
    ["INM_NOTIFY_HOOKS_SUCCESS"]="NOTIFY_HOOKS_SUCCESS: Notify when hooks succeed."
    ["INM_NOTIFY_HEARTBEAT_ENABLED"]="NOTIFY_HEARTBEAT_ENABLED: Enable daily heartbeat."
    ["INM_NOTIFY_HEARTBEAT_TIME"]="NOTIFY_HEARTBEAT_TIME: Heartbeat cron time (HH:MM)."
    ["INM_NOTIFY_HEARTBEAT_LEVEL"]="NOTIFY_HEARTBEAT_LEVEL: Minimum severity for heartbeat."
    ["INM_NOTIFY_HEARTBEAT_FORMAT"]="NOTIFY_HEARTBEAT_FORMAT: Heartbeat summary format (compact|full|failed)."
    ["INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL"]="NOTIFY_HEARTBEAT_DETAIL_LEVEL: Legacy detail fallback (auto=use INM_NOTIFY_HEARTBEAT_LEVEL)."
    ["INM_NOTIFY_HEARTBEAT_INCLUDE"]="NOTIFY_HEARTBEAT_INCLUDE: Include filter for heartbeat checks."
    ["INM_NOTIFY_HEARTBEAT_EXCLUDE"]="NOTIFY_HEARTBEAT_EXCLUDE: Exclude filter for heartbeat checks."
    ["INM_NOTIFY_WEBHOOK_URL"]="NOTIFY_WEBHOOK_URL: Webhook target URL."
    ["INM_MIGRATION_BACKUP"]="MIGRATION_BACKUP: Use LATEST or path for provision restore."
    ["INM_CLI_COMPATIBILITY"]="CLI_COMPATIBILITY: Missing value means legacy install."
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
    ["INM_CLI_ENV_MODE"]="Strict mode for CLI config when fixing perms."
    ["INM_BACKUP_DIR_MODE"]="Optional override for backup dir mode (empty=use INM_DIR_MODE)."
    ["INM_HISTORY_LOG_FILE"]="Path to history log (supports \${INM_BASE_DIRECTORY} and ~)."
    ["INM_HISTORY_LOG_MAX_SIZE"]="Rotate when log exceeds this size (bytes, K, M, G)."
    ["INM_HISTORY_LOG_ROTATE"]="Number of rotated history logs to keep."
    ["INM_AUTO_UPDATE_CHECK"]="Startup update notice for app + CLI (uses last health check results)."
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
    ["INM_NOTIFY_HEARTBEAT_FORMAT"]="Heartbeat summary format (compact|full|failed)."
    ["INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL"]="Legacy heartbeat detail fallback (auto=use INM_NOTIFY_HEARTBEAT_LEVEL)."
    ["INM_NOTIFY_HEARTBEAT_INCLUDE"]="Optional include filter for heartbeat checks."
    ["INM_NOTIFY_HEARTBEAT_EXCLUDE"]="Optional exclude filter for heartbeat checks."
    ["INM_NOTIFY_WEBHOOK_URL"]="Webhook target URL."
    ["INM_MIGRATION_BACKUP"]="Use LATEST or path to run restore after provision."
    ["INM_CLI_COMPATIBILITY"]="Missing => treat as legacy install."
)
