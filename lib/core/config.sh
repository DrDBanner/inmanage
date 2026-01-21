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
    ["INM_PATH_BASE_DIR"]="$PWD/"
    ["INM_PATH_APP_DIR"]="./invoiceninja"
    ["INM_PATH_APP_ENV_FILE"]="\${INM_PATH_BASE_DIR}\${INM_PATH_APP_DIR}/.env"
    ["INM_PATH_TMP_DOWNLOAD_DIR"]="./.temp"
    ["INM_RUNTIME_PHP_BIN"]="$(command -v php)"
    ["INM_RUNTIME_ARTISAN_CMD"]="\${INM_RUNTIME_PHP_BIN} \${INM_PATH_BASE_DIR}\${INM_PATH_APP_DIR}/artisan"
    ["INM_EXEC_SHELL_BIN"]="$(command -v bash)"
    ["INM_SELF_PROGRAM_NAME"]="InvoiceNinja"
    ["INM_SELF_COMPAT_VERSION"]="5+"
    ["INM_SELF_CLI_COMPAT_MODE"]="ultron" # Missing => treat as legacy install.
    ["INM_BACKUP_DIR"]="./.backup"
    ["INM_BACKUP_DIR_PERM_MODE"]="" # Optional override for backup dir mode (empty=use INM_PERM_DIR_MODE).
    ["INM_BACKUP_RETENTION"]="2"
    ["INM_DB_DUMP_OPTIONS"]="--default-character-set=utf8mb4 --no-tablespaces --skip-add-drop-table --quick --single-transaction"
    ["INM_DB_FORCE_READ_PW_ENABLE"]="N"
    ["INM_BACKUP_MIGRATION_SOURCE"]="" # Use LATEST or path to run restore after provision.
    ["INM_CACHE_LOCAL_DIR"]="./.cache"
    ["INM_CACHE_GLOBAL_DIR"]="\${HOME}/.inmanage/cache"
    ["INM_CACHE_GLOBAL_RETENTION"]="3" # Keep last N cached releases.
    ["INM_CACHE_GLOBAL_DIR_PERM_MODE"]="" # Empty = auto (775 if group set, else 750).
    ["INM_CACHE_GLOBAL_FILE_PERM_MODE"]="" # Empty = auto (664 if group set, else 640).
    ["INM_CACHE_SUDO_PROMPT_MODE"]="never" # ask|never to enable sudo prompt for cache dir.
    ["INM_LOG_OPS_FILE"]="\${INM_PATH_BASE_DIR}/.inmanage/history.log"
    ["INM_LOG_OPS_MAX_SIZE"]="512K"
    ["INM_LOG_OPS_ROTATE_COUNT"]="5"
    ["INM_EXEC_USER"]="www-data"
    ["INM_EXEC_GROUP"]="" # Optional group override (defaults to user's primary group).
    ["INM_PERM_DIR_MODE"]="2750" # Default directory mode for app dirs when fixing perms.
    ["INM_PERM_FILE_MODE"]="644" # Default file mode for app files when fixing perms.
    ["INM_PERM_APP_ENV_MODE"]="600" # Strict mode for app .env when fixing perms.
    ["INM_PERM_CLI_ENV_MODE"]="600" # Strict mode for CLI config when fixing perms.
    ["INM_UPDATE_CHECK_ENABLE"]="true" # Show startup update notice for app + CLI (uses last health check results).
    ["INM_HEALTH_CHECK_INCLUDE"]="" # Optional include filter for health checks.
    ["INM_HEALTH_CHECK_EXCLUDE"]="" # Optional exclude filter for health checks.
    ["INM_GH_API_CREDENTIALS"]="" # Format username:password or token:x-oauth.
    ["INM_NOTIFY_ENABLE"]="false" # Enable notifications for non-interactive failures.
    ["INM_NOTIFY_TARGETS_LIST"]="email,webhook" # Comma list: email,webhook.
    ["INM_NOTIFY_EMAIL_TO_LIST"]="" # Comma-separated recipients.
    ["INM_NOTIFY_EMAIL_FROM_ADDRESS"]="" # Override sender address (defaults to app MAIL_FROM_ADDRESS).
    ["INM_NOTIFY_EMAIL_FROM_NAME"]="Heartbeat | Invoice Ninja" # Override sender name (defaults to app MAIL_FROM_NAME).
    ["INM_NOTIFY_LEVEL"]="ERR" # Minimum severity: ERR|WARN|INFO|OK|ALL.
    ["INM_NOTIFY_NONINTERACTIVE_ONLY_ENABLE"]="true" # Only send when no TTY is attached.
    ["INM_NOTIFY_SMTP_TIMEOUT_SECONDS"]="10" # SMTP connect timeout (seconds).
    ["INM_NOTIFY_HOOKS_ENABLE"]="true" # Enable hook notifications.
    ["INM_NOTIFY_HOOKS_FAILURE_ENABLE"]="true" # Notify when hooks fail.
    ["INM_NOTIFY_HOOKS_SUCCESS_ENABLE"]="false" # Notify when hooks succeed.
    ["INM_NOTIFY_HEARTBEAT_ENABLE"]="true" # Enable daily health heartbeat (requires heartbeat cron job).
    ["INM_NOTIFY_HEARTBEAT_TIME"]="06:00" # Heartbeat cron time (HH:MM).
    ["INM_NOTIFY_HEARTBEAT_LEVEL"]="ERR" # Minimum heartbeat severity (ERR|WARN|INFO|OK|ALL).
    ["INM_NOTIFY_HEARTBEAT_FORMAT_MODE"]="compact" # Heartbeat summary format (compact|full|failed).
    ["INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL_MODE"]="auto" # Legacy heartbeat detail fallback (auto=use INM_NOTIFY_HEARTBEAT_LEVEL).
    ["INM_NOTIFY_HEARTBEAT_CHECK_INCLUDE"]="" # Optional include filter for heartbeat checks.
    ["INM_NOTIFY_HEARTBEAT_CHECK_EXCLUDE"]="" # Optional exclude filter for heartbeat checks.
    ["INM_NOTIFY_WEBHOOK_URL"]="" # Webhook target URL.
)

# shellcheck disable=SC2034
default_settings_order=(
    "INM_PATH_BASE_DIR"
    "INM_PATH_APP_DIR"
    "INM_PATH_APP_ENV_FILE"
    "INM_PATH_TMP_DOWNLOAD_DIR"
    "INM_RUNTIME_PHP_BIN"
    "INM_RUNTIME_ARTISAN_CMD"
    "INM_EXEC_SHELL_BIN"
    "INM_SELF_PROGRAM_NAME"
    "INM_SELF_COMPAT_VERSION"
    "INM_SELF_CLI_COMPAT_MODE"
    "INM_BACKUP_DIR"
    "INM_BACKUP_DIR_PERM_MODE"
    "INM_BACKUP_RETENTION"
    "INM_DB_DUMP_OPTIONS"
    "INM_DB_FORCE_READ_PW_ENABLE"
    "INM_BACKUP_MIGRATION_SOURCE"
    "INM_CACHE_LOCAL_DIR"
    "INM_CACHE_GLOBAL_DIR"
    "INM_CACHE_GLOBAL_RETENTION"
    "INM_CACHE_GLOBAL_DIR_PERM_MODE"
    "INM_CACHE_GLOBAL_FILE_PERM_MODE"
    "INM_CACHE_SUDO_PROMPT_MODE"
    "INM_LOG_OPS_FILE"
    "INM_LOG_OPS_MAX_SIZE"
    "INM_LOG_OPS_ROTATE_COUNT"
    "INM_EXEC_USER"
    "INM_EXEC_GROUP"
    "INM_PERM_DIR_MODE"
    "INM_PERM_FILE_MODE"
    "INM_PERM_APP_ENV_MODE"
    "INM_PERM_CLI_ENV_MODE"
    "INM_UPDATE_CHECK_ENABLE"
    "INM_HEALTH_CHECK_INCLUDE"
    "INM_HEALTH_CHECK_EXCLUDE"
    "INM_GH_API_CREDENTIALS"
    "INM_NOTIFY_ENABLE"
    "INM_NOTIFY_TARGETS_LIST"
    "INM_NOTIFY_EMAIL_TO_LIST"
    "INM_NOTIFY_EMAIL_FROM_ADDRESS"
    "INM_NOTIFY_EMAIL_FROM_NAME"
    "INM_NOTIFY_LEVEL"
    "INM_NOTIFY_NONINTERACTIVE_ONLY_ENABLE"
    "INM_NOTIFY_SMTP_TIMEOUT_SECONDS"
    "INM_NOTIFY_HOOKS_ENABLE"
    "INM_NOTIFY_HOOKS_FAILURE_ENABLE"
    "INM_NOTIFY_HOOKS_SUCCESS_ENABLE"
    "INM_NOTIFY_HEARTBEAT_ENABLE"
    "INM_NOTIFY_HEARTBEAT_TIME"
    "INM_NOTIFY_HEARTBEAT_LEVEL"
    "INM_NOTIFY_HEARTBEAT_FORMAT_MODE"
    "INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL_MODE"
    "INM_NOTIFY_HEARTBEAT_CHECK_INCLUDE"
    "INM_NOTIFY_HEARTBEAT_CHECK_EXCLUDE"
    "INM_NOTIFY_WEBHOOK_URL"
)

# shellcheck disable=SC2034
prompt_order=(
    "INM_PATH_BASE_DIR"
    "INM_PATH_APP_DIR"
    "INM_BACKUP_RETENTION"
    "INM_DB_FORCE_READ_PW_ENABLE"
    "INM_EXEC_USER"
    "INM_EXEC_GROUP"
    "INM_GH_API_CREDENTIALS"
)

# shellcheck disable=SC2034,SC2190
declare -A prompt_texts=(
    ["INM_PATH_BASE_DIR"]="BASE_DIRECTORY: This will contain your Invoice Ninja app directory (next step). It's not the webserver docroot. Define your desired location or keep."
    ["INM_PATH_APP_DIR"]="INSTALLATION_DIRECTORY: Invoice Ninja app directory. The web server usually serves from <INSTALLATION_DIRECTORY>/public. Define your desired location or keep."
    ["INM_PATH_APP_ENV_FILE"]="ENV_FILE: Path to the Invoice Ninja .env file. Usually keep default."
    ["INM_RUNTIME_PHP_BIN"]="PHP_EXECUTABLE: Path to php binary. In doubt, keep as is."
    ["INM_RUNTIME_ARTISAN_CMD"]="ARTISAN_STRING: Command used to call artisan."
    ["INM_EXEC_SHELL_BIN"]="ENFORCED_SHELL: Shell used for cron and hooks. In doubt, keep as is."
    ["INM_SELF_PROGRAM_NAME"]="PROGRAM_NAME: Label used for backups and outputs."
    ["INM_SELF_COMPAT_VERSION"]="COMPATIBILITY_VERSION: Invoice Ninja compatibility hint."
    ["INM_SELF_CLI_COMPAT_MODE"]="CLI_COMPATIBILITY: Missing value means legacy install."
    ["INM_BACKUP_DIR"]="BACKUP_DIRECTORY: Define your desired location or keep."
    ["INM_BACKUP_DIR_PERM_MODE"]="BACKUP_DIR_MODE: Optional mode for the backup directory (empty=use DIR_MODE)."
    ["INM_BACKUP_RETENTION"]="KEEP_BACKUPS: Backup retention. Set to 2 to keep 2 backups in the past at a time."
    ["INM_DB_DUMP_OPTIONS"]="DUMP_OPTIONS: Modify database dump options. In doubt, keep defaults."
    ["INM_DB_FORCE_READ_PW_ENABLE"]="FORCE_READ_DB_PW: Include DB password in CLI? (Y) convenient but exposes the password during runtime. (N) assumes a secure .my.cnf."
    ["INM_BACKUP_MIGRATION_SOURCE"]="MIGRATION_BACKUP: Use LATEST or path for provision restore."
    ["INM_CACHE_LOCAL_DIR"]="CACHE_LOCAL_DIRECTORY: Local (project) cache directory."
    ["INM_CACHE_GLOBAL_DIR"]="CACHE_GLOBAL_DIRECTORY: Shared/global cache directory."
    ["INM_CACHE_GLOBAL_RETENTION"]="CACHE_GLOBAL_RETENTION: Keep last N cached releases."
    ["INM_CACHE_GLOBAL_DIR_PERM_MODE"]="CACHE_DIR_MODE: Permission mode for cache directories (empty=auto)."
    ["INM_CACHE_GLOBAL_FILE_PERM_MODE"]="CACHE_FILE_MODE: Permission mode for cache files (empty=auto)."
    ["INM_CACHE_SUDO_PROMPT_MODE"]="CACHE_SUDO_PROMPT: ask or never to use sudo for cache dirs."
    ["INM_LOG_OPS_FILE"]="HISTORY_LOG_FILE: Path to the history log file."
    ["INM_LOG_OPS_MAX_SIZE"]="HISTORY_LOG_MAX_SIZE: Rotate when log exceeds this size (bytes, K, M, G)."
    ["INM_LOG_OPS_ROTATE_COUNT"]="HISTORY_LOG_ROTATE: Number of rotated history logs to keep."
    ["INM_EXEC_USER"]="ENFORCED_USER: Correct setting helps mitigate permission issues. Usually the webserver user. On shared hosting often your current user."
    ["INM_EXEC_GROUP"]="ENFORCED_GROUP: Optional group override for ownership."
    ["INM_PERM_DIR_MODE"]="DIR_MODE: Default directory mode when fixing perms."
    ["INM_PERM_FILE_MODE"]="FILE_MODE: Default file mode when fixing perms."
    ["INM_PERM_APP_ENV_MODE"]="ENV_MODE: Mode for app .env when fixing perms."
    ["INM_PERM_CLI_ENV_MODE"]="CLI_ENV_MODE: Mode for CLI .env.inmanage when fixing perms."
    ["INM_UPDATE_CHECK_ENABLE"]="AUTO_UPDATE_CHECK: Show stored app + CLI update notice on CLI start (from last health)."
    ["INM_HEALTH_CHECK_INCLUDE"]="HEALTH_CHECK_INCLUDE: Include filter for health checks."
    ["INM_HEALTH_CHECK_EXCLUDE"]="HEALTH_CHECK_EXCLUDE: Exclude filter for health checks."
    ["INM_GH_API_CREDENTIALS"]="GH_API_CREDENTIALS: GitHub API credentials (username:password or token:x-oauth)."
    ["INM_NOTIFY_ENABLE"]="NOTIFY_ENABLED: Enable notifications for non-interactive failures."
    ["INM_NOTIFY_TARGETS_LIST"]="NOTIFY_TARGETS: Comma list of targets (email,webhook)."
    ["INM_NOTIFY_EMAIL_TO_LIST"]="NOTIFY_EMAIL_TO: Comma-separated recipients."
    ["INM_NOTIFY_EMAIL_FROM_ADDRESS"]="NOTIFY_EMAIL_FROM: Override sender address."
    ["INM_NOTIFY_EMAIL_FROM_NAME"]="NOTIFY_EMAIL_FROM_NAME: Override sender name."
    ["INM_NOTIFY_LEVEL"]="NOTIFY_LEVEL: Minimum severity (ERR|WARN|INFO|OK|ALL)."
    ["INM_NOTIFY_NONINTERACTIVE_ONLY_ENABLE"]="NOTIFY_NONINTERACTIVE_ONLY: Only send when no TTY is attached."
    ["INM_NOTIFY_SMTP_TIMEOUT_SECONDS"]="NOTIFY_SMTP_TIMEOUT: SMTP connect timeout (seconds)."
    ["INM_NOTIFY_HOOKS_ENABLE"]="NOTIFY_HOOKS_ENABLED: Enable hook notifications."
    ["INM_NOTIFY_HOOKS_FAILURE_ENABLE"]="NOTIFY_HOOKS_FAILURE: Notify when hooks fail."
    ["INM_NOTIFY_HOOKS_SUCCESS_ENABLE"]="NOTIFY_HOOKS_SUCCESS: Notify when hooks succeed."
    ["INM_NOTIFY_HEARTBEAT_ENABLE"]="NOTIFY_HEARTBEAT_ENABLED: Enable daily heartbeat."
    ["INM_NOTIFY_HEARTBEAT_TIME"]="NOTIFY_HEARTBEAT_TIME: Heartbeat cron time (HH:MM)."
    ["INM_NOTIFY_HEARTBEAT_LEVEL"]="NOTIFY_HEARTBEAT_LEVEL: Minimum severity for heartbeat."
    ["INM_NOTIFY_HEARTBEAT_FORMAT_MODE"]="NOTIFY_HEARTBEAT_FORMAT: Heartbeat summary format (compact|full|failed)."
    ["INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL_MODE"]="NOTIFY_HEARTBEAT_DETAIL_LEVEL: Legacy detail fallback (auto=use INM_NOTIFY_HEARTBEAT_LEVEL)."
    ["INM_NOTIFY_HEARTBEAT_CHECK_INCLUDE"]="NOTIFY_HEARTBEAT_CHECK_INCLUDE: Include filter for heartbeat checks."
    ["INM_NOTIFY_HEARTBEAT_CHECK_EXCLUDE"]="NOTIFY_HEARTBEAT_CHECK_EXCLUDE: Exclude filter for heartbeat checks."
    ["INM_NOTIFY_WEBHOOK_URL"]="NOTIFY_WEBHOOK_URL: Webhook target URL."
)

# shellcheck disable=SC2034,SC2190
declare -A default_inline_comments=(
    ["INM_PATH_BASE_DIR"]="Base directory containing the app folder."
    ["INM_PATH_APP_DIR"]="App directory relative to the base directory."
    ["INM_PATH_APP_ENV_FILE"]="Path to the app .env file."
    ["INM_PATH_TMP_DOWNLOAD_DIR"]="Temporary download directory for CLI updates."
    ["INM_RUNTIME_PHP_BIN"]="Path to the PHP executable."
    ["INM_RUNTIME_ARTISAN_CMD"]="Artisan command used by the CLI."
    ["INM_EXEC_SHELL_BIN"]="Shell used for cron and hooks."
    ["INM_SELF_PROGRAM_NAME"]="Label used for outputs and backups."
    ["INM_SELF_COMPAT_VERSION"]="Invoice Ninja compatibility hint."
    ["INM_BACKUP_DIR"]="Backup directory."
    ["INM_BACKUP_DIR_PERM_MODE"]="Optional override for backup dir mode (empty=use INM_PERM_DIR_MODE)."
    ["INM_BACKUP_RETENTION"]="Keep last N backups."
    ["INM_DB_DUMP_OPTIONS"]="Database dump options."
    ["INM_DB_FORCE_READ_PW_ENABLE"]="Include DB password in CLI (Y/N)."
    ["INM_CACHE_GLOBAL_DIR_PERM_MODE"]="Empty = auto (775 if group set, else 750)."
    ["INM_CACHE_GLOBAL_FILE_PERM_MODE"]="Empty = auto (664 if group set, else 640)."
    ["INM_CACHE_SUDO_PROMPT_MODE"]="ask|never to enable sudo prompt for cache dir."
    ["INM_CACHE_LOCAL_DIR"]="Local (project) cache directory."
    ["INM_CACHE_GLOBAL_DIR"]="Global cache directory."
    ["INM_CACHE_GLOBAL_RETENTION"]="Keep last N cached releases."
    ["INM_SELF_CLI_COMPAT_MODE"]="Missing => treat as legacy install."
    ["INM_PERM_CLI_ENV_MODE"]="Strict mode for CLI config when fixing perms."
    ["INM_PERM_DIR_MODE"]="Default directory mode for app dirs when fixing perms."
    ["INM_PERM_APP_ENV_MODE"]="Strict mode for app .env when fixing perms."
    ["INM_EXEC_USER"]="User used to run CLI actions."
    ["INM_EXEC_GROUP"]="Optional group override (defaults to user's primary group)."
    ["INM_PERM_FILE_MODE"]="Default file mode for app files when fixing perms."
    ["INM_GH_API_CREDENTIALS"]="Format username:password or token:x-oauth."
    ["INM_LOG_OPS_FILE"]="Path to history log (supports \${INM_PATH_BASE_DIR} and ~)."
    ["INM_LOG_OPS_MAX_SIZE"]="Rotate when log exceeds this size (bytes, K, M, G)."
    ["INM_LOG_OPS_ROTATE_COUNT"]="Number of rotated history logs to keep."
    ["INM_UPDATE_CHECK_ENABLE"]="Startup update notice for app + CLI (uses last health check results)."
    ["INM_HEALTH_CHECK_INCLUDE"]="Optional include filter for health checks."
    ["INM_HEALTH_CHECK_EXCLUDE"]="Optional exclude filter for health checks."
    ["INM_BACKUP_MIGRATION_SOURCE"]="Use LATEST or path to run restore after provision."
    ["INM_NOTIFY_ENABLE"]="Enable notifications for non-interactive failures."
    ["INM_NOTIFY_TARGETS_LIST"]="Comma list: email,webhook."
    ["INM_NOTIFY_EMAIL_TO_LIST"]="Comma-separated recipients."
    ["INM_NOTIFY_EMAIL_FROM_ADDRESS"]="Override sender address (defaults to app MAIL_FROM_ADDRESS)."
    ["INM_NOTIFY_EMAIL_FROM_NAME"]="Override sender name (defaults to app MAIL_FROM_NAME)."
    ["INM_NOTIFY_LEVEL"]="Minimum severity: ERR|WARN|INFO|OK|ALL."
    ["INM_NOTIFY_NONINTERACTIVE_ONLY_ENABLE"]="Only send when no TTY is attached."
    ["INM_NOTIFY_SMTP_TIMEOUT_SECONDS"]="SMTP connect timeout (seconds)."
    ["INM_NOTIFY_HOOKS_ENABLE"]="Enable hook notifications."
    ["INM_NOTIFY_HOOKS_FAILURE_ENABLE"]="Notify when hooks fail."
    ["INM_NOTIFY_HOOKS_SUCCESS_ENABLE"]="Notify when hooks succeed."
    ["INM_NOTIFY_HEARTBEAT_ENABLE"]="Enable daily health heartbeat (requires heartbeat cron job)."
    ["INM_NOTIFY_HEARTBEAT_TIME"]="Heartbeat cron time (HH:MM)."
    ["INM_NOTIFY_HEARTBEAT_LEVEL"]="Minimum heartbeat severity (ERR|WARN|INFO|OK|ALL)."
    ["INM_NOTIFY_HEARTBEAT_FORMAT_MODE"]="Heartbeat summary format (compact|full|failed)."
    ["INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL_MODE"]="Legacy heartbeat detail fallback (auto=use INM_NOTIFY_HEARTBEAT_LEVEL)."
    ["INM_NOTIFY_HEARTBEAT_CHECK_INCLUDE"]="Optional include filter for heartbeat checks."
    ["INM_NOTIFY_HEARTBEAT_CHECK_EXCLUDE"]="Optional exclude filter for heartbeat checks."
    ["INM_NOTIFY_WEBHOOK_URL"]="Webhook target URL."
    ["INM_SELF_INSTANCE_ID"]="Instance identifier (auto-generated)."
)
