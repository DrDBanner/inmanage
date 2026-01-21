#!/usr/bin/env bash
set -eE

# Resolve script directory even when called via symlink.
_resolve_self() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ $src != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

SCRIPT_DIR="$(_resolve_self)"
LIB_DIR="${SCRIPT_DIR}/lib"

if [ -f "${LIB_DIR}/core/env.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/core/env.sh"
else
    echo "[ERR] Missing env module: ${LIB_DIR}/core/env.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/args.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/args.sh"
else
    echo "[ERR] Missing args helper: ${LIB_DIR}/helpers/args.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/env_parse.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/env_parse.sh"
else
    echo "[ERR] Missing env parse helper: ${LIB_DIR}/helpers/env_parse.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/env_read.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/env_read.sh"
else
    echo "[ERR] Missing env read helper: ${LIB_DIR}/helpers/env_read.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/php_utils.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/php_utils.sh"
else
    echo "[ERR] Missing PHP helper: ${LIB_DIR}/helpers/php_utils.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/distro_compatibility.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/distro_compatibility.sh"
    compat_init
else
    echo "[ERR] Missing distro compatibility helper: ${LIB_DIR}/helpers/distro_compatibility.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/prompt.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/prompt.sh"
else
    echo "[ERR] Missing prompt helper: ${LIB_DIR}/helpers/prompt.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/db_client.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/db_client.sh"
else
    echo "[ERR] Missing db client helper: ${LIB_DIR}/helpers/db_client.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/selection.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/selection.sh"
else
    echo "[ERR] Missing selection helper: ${LIB_DIR}/helpers/selection.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/hooks.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/hooks.sh"
else
    echo "[ERR] Missing hooks helper: ${LIB_DIR}/helpers/hooks.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/spinner.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/spinner.sh"
else
    echo "[ERR] Missing spinner helper: ${LIB_DIR}/helpers/spinner.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/fs.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/fs.sh"
else
    echo "[ERR] Missing fs helper: ${LIB_DIR}/helpers/fs.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/update_notice.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/update_notice.sh"
else
    echo "[ERR] Missing update notice helper: ${LIB_DIR}/helpers/update_notice.sh" >&2
    exit 1
fi

if declare -F ops_log_on_error >/dev/null 2>&1; then
    trap 'ops_log_on_error' ERR
fi

if [ -f "${LIB_DIR}/helpers/user.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/user.sh"
else
    echo "[ERR] Missing user helper: ${LIB_DIR}/helpers/user.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/install_output.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/install_output.sh"
else
    echo "[ERR] Missing install output helper: ${LIB_DIR}/helpers/install_output.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/resolve.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/resolve.sh"
else
    echo "[ERR] Missing resolve helper: ${LIB_DIR}/helpers/resolve.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/sys_utils.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/sys_utils.sh"
else
    echo "[ERR] Missing system helper: ${LIB_DIR}/helpers/sys_utils.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/git_utils.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/git_utils.sh"
else
    echo "[ERR] Missing git helper: ${LIB_DIR}/helpers/git_utils.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/cli_info.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/cli_info.sh"
else
    echo "[ERR] Missing CLI info helper: ${LIB_DIR}/helpers/cli_info.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/helpers/http_utils.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/http_utils.sh"
else
    echo "[ERR] Missing http helper: ${LIB_DIR}/helpers/http_utils.sh" >&2
    exit 1
fi
if [ -f "${LIB_DIR}/helpers/gh_utils.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/gh_utils.sh"
else
    echo "[ERR] Missing GitHub helper: ${LIB_DIR}/helpers/gh_utils.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/core/cli.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/core/cli.sh"
else
    echo "[ERR] Missing cli module: ${LIB_DIR}/core/cli.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/core/config.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/core/config.sh"
else
    echo "[ERR] Missing config module: ${LIB_DIR}/core/config.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/core/checks.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/core/checks.sh"
else
    echo "[ERR] Missing checks module: ${LIB_DIR}/core/checks.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/core.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/core.sh"
else
    echo "[ERR] Missing core service module: ${LIB_DIR}/services/core.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/db.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/db.sh"
else
    echo "[ERR] Missing db service module: ${LIB_DIR}/services/db.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/config.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/config.sh"
else
    echo "[ERR] Missing config service module: ${LIB_DIR}/services/config.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/install.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/install.sh"
else
    echo "[ERR] Missing install service module: ${LIB_DIR}/services/install.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/self_install.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/self_install.sh"
else
    echo "[ERR] Missing self-install service module: ${LIB_DIR}/services/self_install.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/restore.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/restore.sh"
fi

if [ -f "${LIB_DIR}/services/env.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/env.sh"
fi

if [ -f "${LIB_DIR}/services/update.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/update.sh"
else
    echo "[ERR] Missing update service module: ${LIB_DIR}/services/update.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/backup.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/backup.sh"
else
    echo "[ERR] Missing backup service module: ${LIB_DIR}/services/backup.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/cleanup.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/cleanup.sh"
else
    echo "[ERR] Missing cleanup service module: ${LIB_DIR}/services/cleanup.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/cron.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/cron.sh"
else
    echo "[ERR] Missing cron service module: ${LIB_DIR}/services/cron.sh" >&2
    exit 1
fi

if [ -f "${LIB_DIR}/services/notify.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/notify.sh"
fi

if [ -f "${LIB_DIR}/services/preflight.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/preflight.sh"
else
    echo "[ERR] Missing preflight service module: ${LIB_DIR}/services/preflight.sh" >&2
    exit 1
fi
if [ -f "${LIB_DIR}/services/web.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/web.sh"
fi
if [ -f "${LIB_DIR}/services/pdf.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/pdf.sh"
fi
if [ -f "${LIB_DIR}/services/provision.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/services/provision.sh"
fi

# Call the environment setup before doing anything else
setup_environment
require_functions \
    check_commands_list check_commands_missing \
    spinner_start spinner_stop spinner_run spinner_run_optional spinner_run_quiet spinner_run_mode \
    run_hook \
    resolve_script_path resolve_cli_command_path ensure_trailing_slash resolve_env_paths compute_installation_path assert_file_path \
    read_env_value_safe read_env_value env_set _env_key_is_sensitive _env_parse_env_value \
    trace_can_guard trace_suspend trace_resume trace_suspend_if_sensitive_key \
    enforce_ownership enforce_dir_permissions enforce_file_permissions fs_user_can_write fs_sync_dir fs_sync_path \
    app_parse_rollback_target app_build_rollback_hint app_log_rollback_hint \
    apply_cache_dir_mode \
    get_installed_version get_latest_version version_compare get_app_release \
    gh_release_list_versions gh_release_download gh_release_fetch_digest \
    compat_compute_sha256 file_read_state \
    notify_bool notify_emit_event notify_send_email notify_send_webhook notify_email_format_html \
    web_emit_preflight webphp_emit_preflight \
    snappdf_emit_preflight \
    preflight_pick_probe_dir preflight_ensure_dir preflight_track_created_dir preflight_cleanup_created_dirs preflight_write_probe_file \
    preflight_require_commands preflight_hydrate_app_url preflight_get_default_groups preflight_print_summary preflight_build_notify_summary \
    prompt_confirm
require_rc=$?
if [ "$require_rc" -ne 0 ]; then
    exit "$require_rc"
fi
if [ "$DEBUG" = true ]; then
    log debug "[BOOT] Loaded modules from $LIB_DIR (env,args,prompt,selection,fs,user,resolve,cli,config,checks,services)"
fi

function_caller() {
    case "$1" in
    clean_install)
        NAMED_ARGS["clean"]=true
        force_update=true
        run_installation
        ;;
    install)
        run_installation
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
    import_db)
        import_database
        ;;
    cleanup_versions)
        cleanup_old_versions
        ;;
    cleanup_backups)
        cleanup_old_backups
        ;;
    cleanup)
        cleanup
        ;;
    install_cronjob)
        install_cronjob
        ;;
    install_self)
        install_self
        ;;
    preflight)
        run_preflight
        ;;
    *)
        return 1
        ;;
    esac
}

force_update=false
DEBUG=false
DEBUG_LEVEL=0
CMD_CONTEXT=""
CMD_ACTION=""
SHOW_FUNCTION_HELP=false
DRY_RUN=false
# TODO: Refactor globals (INM_*/DB_*/NAMED_ARGS) to a passed config/ctx object parameters to reduce side effects.

parse_options "$@"

debug_level="${DEBUG_LEVEL:-0}"
trace_guard_dispatch=false
if [[ "$debug_level" =~ ^[0-9]+$ && "$debug_level" -ge 2 ]]; then
    if trace_can_guard && [[ "$CMD_CONTEXT" == "env" ]]; then
        case "$CMD_ACTION" in
            show)
                trace_guard_dispatch=true
                ;;
            get|set)
                trace_key="${CMD_EXTRA[0]:-}"
                if [[ "$trace_key" == "app" || "$trace_key" == "cli" ]]; then
                    trace_key="${CMD_EXTRA[1]:-}"
                fi
                trace_key="${trace_key%%=*}"
                if [[ -n "$trace_key" ]] && _env_key_is_sensitive "$trace_key"; then
                    trace_guard_dispatch=true
                fi
                ;;
        esac
    fi
fi
if [[ "$debug_level" =~ ^[0-9]+$ && "$debug_level" -ge 2 ]]; then
    export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
    set -o xtrace
fi

# Compact output: default for self/-v unless explicitly overridden.
if [[ -n "${NAMED_ARGS[compact]:-}" ]]; then
    if args_is_true "${NAMED_ARGS[compact]}"; then
        INM_COMPACT_OUTPUT=true
    else
        INM_COMPACT_OUTPUT=false
    fi
elif [[ -z "${INM_COMPACT_OUTPUT:-}" ]]; then
    if [[ "$CMD_CONTEXT" == "self" || "${LEGACY_CMD:-}" == "version" ]]; then
        INM_COMPACT_OUTPUT=true
    fi
fi

if [ "$DEBUG" = true ]; then
    printf -v _args '%q ' "$@"
    log debug "Args after: $_args"
fi

if [[ "$SHOW_FUNCTION_HELP" == true ]]; then
    help_ctx="$CMD_CONTEXT"
    help_action="$CMD_ACTION"
    if [[ -z "$help_ctx" && -n "$LEGACY_CMD" ]]; then
        case "$LEGACY_CMD" in
            info|health) help_ctx="core"; help_action="health";;
            version) help_ctx="self"; help_action="version";;
            clear-cache|clear_cache) help_ctx="core"; help_action="clear-cache";;
            backup) help_ctx="core"; help_action="backup";;
            cleanup|prune) help_ctx="core"; help_action="prune";;
            cleanup_versions|prune_versions) help_ctx="core"; help_action="prune_versions";;
            cleanup_backups|prune_backups) help_ctx="core"; help_action="prune_backups";;
            *) help_ctx="$LEGACY_CMD";;
        esac
    fi
    case "$help_ctx" in
        install|update|backup|restore|cron|provision|prune|prune_versions|prune-versions|prune_backups|prune-backups|clear-cache|clear_cache)
            help_action="$help_ctx"
            help_ctx="core"
            ;;
    esac
    log debug "[SFH] Showing help. Context: ${help_ctx:-<none>} Action: ${CMD_ACTION:-<none>} Legacy: ${LEGACY_CMD:-<none>}"
    if [[ -n "$help_ctx" && -n "$help_action" ]]; then
        show_action_help "$help_ctx" "$help_action"
    elif [[ -n "$help_ctx" ]]; then
        show_context_help "$help_ctx"
    else
        show_function_help
    fi
    exit 0
fi

cmd_check_mode="full"
if [[ "$CMD_CONTEXT" == "self" ]]; then
    if [[ "$CMD_ACTION" == "update" ]]; then
        cmd_check_mode="self_update"
    else
        cmd_check_mode="self"
    fi
elif [[ "${LEGACY_CMD:-}" == "version" ]]; then
    cmd_check_mode="self"
elif [[ "$CMD_CONTEXT" == "core" && ( "$CMD_ACTION" == "health" || "$CMD_ACTION" == "info" ) ]]; then
    cmd_check_mode="preflight"
elif [[ "${LEGACY_CMD:-}" == "health" || "${LEGACY_CMD:-}" == "info" ]]; then
    cmd_check_mode="preflight"
fi
check_commands "$cmd_check_mode"
check_envs "$@"
check_gh_credentials

# contexts/actions that should not clear or print logo
skip_clear_logo=false
if [[ "${NO_CLI_CLEAR:-}" == true || "${NAMED_ARGS[no_cli_clear]:-}" == true ]]; then
    skip_clear_logo=true
elif [[ "${INM_NO_CLI_CLEAR:-}" =~ ^(1|true|yes)$ ]]; then
    skip_clear_logo=true
fi
if [[ "$CMD_CONTEXT" == "env" ]]; then
    skip_clear_logo=true
fi
if [[ "$CMD_CONTEXT" == "self" && "$CMD_ACTION" == "version" ]]; then
    skip_clear_logo=true
fi
if [[ "$CMD_CONTEXT" == "core" && "$CMD_ACTION" == "version" ]]; then
    skip_clear_logo=true
fi
if [[ "$CMD_CONTEXT" == "core" && "$CMD_ACTION" == "versions" ]]; then
    skip_clear_logo=true
fi
if [[ "${LEGACY_CMD:-}" == "version" ]]; then
    skip_clear_logo=true
fi
if [[ "$SHOW_FUNCTION_HELP" == true || "$CMD_ACTION" == "help" || "$CMD_CONTEXT" == "help" ]]; then
    skip_clear_logo=true
fi

if [[ "$skip_clear_logo" != true ]]; then
    safe_clear
    if [[ -z "${INM_CHILD_REEXEC:-}" ]]; then
        print_logo
    fi
fi

log debug "Context: ${CMD_CONTEXT:-<none>} Action: ${CMD_ACTION:-<none>} Legacy: ${LEGACY_CMD:-<none>} Force: $force_update | Debug: $DEBUG | Dry-Run (not implemented): $DRY_RUN"

startup_update_notice() {
    local enabled="${INM_AUTO_UPDATE_CHECK:-false}"
    if [[ -n "${NAMED_ARGS[check_updates]:-}" || -n "${NAMED_ARGS[check-updates]:-}" ]]; then
        enabled="${NAMED_ARGS[check_updates]:-${NAMED_ARGS[check-updates]:-}}"
    fi
    args_is_true "$enabled" || return 0
    case "${CMD_CONTEXT:-}:${CMD_ACTION:-}:${LEGACY_CMD:-}" in
        core:health:*|core:info:*|core:update:*|core:versions:*|core:version:*|core:backup:*|core:restore:*|db:backup:*|files:backup:*|self:update:*|self:install:*|self:version:*|help:*|*:help:*|*:*:help|*:backup:*|*:restore:*)
            return 0
            ;;
    esac
    if declare -F update_notice_emit >/dev/null 2>&1; then
        update_notice_emit
    fi
}

startup_update_notice

# Helper to pass current NAMED_ARGS to a function along with optional positional args.
call_with_named_args() {
    local fn="$1"
    shift
    local positional=("$@")
    local cmd_args=()
    for key in "${!NAMED_ARGS[@]}"; do
        cmd_args+=("--$key=${NAMED_ARGS[$key]}")
    done
    log debug "[INVOKE] $fn ${positional[*]} ${cmd_args[*]}"
    "$fn" "${positional[@]}" "${cmd_args[@]}"
}

skip_if_dry_run() {
    local msg="$1"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would: $msg"
        return 0  # signal caller to skip execution
    fi
    return 1      # execute normally
}

dispatch_command() {
    local ctx="$1"
    local action="$2"
    shift 2
    local extra=("$@")

    log debug "[DISPATCH] ctx=$ctx action=$action extra=${extra[*]}"

    case "$ctx" in
        core)
            case "$action" in
            install)
                local sub="${extra[0]:-}"
                if [[ "$sub" == "rollback" ]]; then
                    if skip_if_dry_run "core install rollback"; then return 0; fi
                    ops_log_begin "install_rollback"
                    call_with_named_args run_install_rollback "${extra[1]:-}"
                    ops_log_end $?
                else
                    [[ "${NAMED_ARGS[clean]:-false}" == true ]] && force_update=true
                    local mode=""
                        [[ "${NAMED_ARGS[provision]:-false}" == true ]] && mode="Provisioned"
                        if skip_if_dry_run "core install"; then return 0; fi
                        export INM_HISTORY_LOG_VERBOSE="install"
                        ops_log_begin "install"
                        call_with_named_args run_installation "$mode"
                        ops_log_end $?
                        unset INM_HISTORY_LOG_VERBOSE
                fi
                    ;;
            update)
                local sub="${extra[0]:-}"
                if [[ "$sub" == "rollback" ]]; then
                    if skip_if_dry_run "core update rollback"; then return 0; fi
                    ops_log_begin "rollback"
                    call_with_named_args run_update_rollback "${extra[1]:-}"
                    ops_log_end $?
                else
                    if skip_if_dry_run "core update"; then return 0; fi
                    export INM_HISTORY_LOG_VERBOSE="update"
                    ops_log_begin "update"
                    call_with_named_args run_update
                    ops_log_end $?
                    unset INM_HISTORY_LOG_VERBOSE
                fi
                ;;
            info|health)
                export INM_PREFLIGHT_LABEL="HEALTH"
                call_with_named_args run_preflight
                ;;
            version)
                log warn "[core] 'core version' is deprecated; use 'core versions'."
                call_with_named_args show_versions_summary
                ;;
            versions)
                call_with_named_args show_versions_summary
                ;;
            get)
                local sub="${extra[0]:-}"
                case "$sub" in
                    app|"")
                        call_with_named_args get_app_release
                        ;;
                    *)
                        log err "[core] Unknown get target: $sub"
                        return 1
                        ;;
                esac
                ;;
            backup)
                NAMED_ARGS["fullbackup"]=true
                if skip_if_dry_run "core backup"; then return 0; fi
                ops_log_begin "backup"
                call_with_named_args run_backup
                ops_log_end $?
                ;;
            restore)
                local sub="${extra[0]:-}"
                if [[ "$sub" == "rollback" ]]; then
                    if skip_if_dry_run "core restore rollback"; then return 0; fi
                    ops_log_begin "restore_rollback"
                    call_with_named_args run_restore_rollback "${extra[1]:-}"
                    ops_log_end $?
                else
                    if skip_if_dry_run "core restore"; then return 0; fi
                    ops_log_begin "restore"
                    call_with_named_args run_restore
                    ops_log_end $?
                fi
                    ;;
            cron)
                local sub="${extra[0]:-install}"
                if [[ "$sub" == "install" ]]; then
                    if skip_if_dry_run "core cron install"; then return 0; fi
                    ops_log_begin "cron_install"
                    call_with_named_args install_cronjob
                    ops_log_end $?
                elif [[ "$sub" == "uninstall" || "$sub" == "remove" ]]; then
                    if skip_if_dry_run "core cron uninstall"; then return 0; fi
                    ops_log_begin "cron_uninstall"
                    call_with_named_args uninstall_cronjob
                    ops_log_end $?
                else
                    log err "[core] Unknown cron action: $sub"
                    return 1
                fi
                ;;
            prune)
                if skip_if_dry_run "core cleanup"; then return 0; fi
                ops_log_begin "prune"
                call_with_named_args cleanup
                ops_log_end $?
                ;;
            prune_versions|prune-versions|clean_versions|clean-versions)
                    if skip_if_dry_run "core cleanup_versions"; then return 0; fi
                    ops_log_begin "prune_versions"
                    call_with_named_args cleanup_old_versions
                    ops_log_end $?
                    ;;
                prune_backups|prune-backups|clean_backups|clean-backups)
                    if skip_if_dry_run "core cleanup_backups"; then return 0; fi
                    ops_log_begin "prune_backups"
                    call_with_named_args cleanup_old_backups
                    ops_log_end $?
                    ;;
                clear-cache|clear_cache)
                    if declare -f clear_application_cache >/dev/null; then
                        call_with_named_args clear_application_cache
                    else
                        log err "[core] clear_application_cache not available."
                        return 1
                    fi
                    ;;
                *)
                    log err "[core] Unknown action: $action"
                    return 1
                    ;;
            esac
            ;;
        spawn)
            case "$action" in
                provision-file|provision_file)
                    if skip_if_dry_run "spawn provision-file"; then return 0; fi
                    call_with_named_args spawn_provision_file
                    ;;
                *)
                    log err "[spawn] Unknown action: $action"
                    return 1
                    ;;
            esac
            ;;
        db)
            case "$action" in
                backup)
                    NAMED_ARGS["db"]=true
                    NAMED_ARGS["fullbackup"]=false
                    NAMED_ARGS["include_app"]=false
                    NAMED_ARGS["storage"]=false
                    NAMED_ARGS["uploads"]=false
                    if skip_if_dry_run "db backup"; then return 0; fi
                    ops_log_begin "backup"
                    call_with_named_args run_backup
                    ops_log_end $?
                    ;;
                restore)
                    if skip_if_dry_run "db restore"; then return 0; fi
                    call_with_named_args import_database
                    ;;
                purge)
                    if skip_if_dry_run "db purge"; then return 0; fi
                    call_with_named_args purge_database
                    ;;
                create)
                    if skip_if_dry_run "db create"; then return 0; fi
                    call_with_named_args create_database
                    ;;
                prune|cleanup)
                    if skip_if_dry_run "db prune"; then return 0; fi
                    ops_log_begin "prune_backups"
                    call_with_named_args cleanup_old_backups
                    ops_log_end $?
                    ;;
                *)
                    log err "[db] Unknown action: $action"
                    return 1
                    ;;
            esac
            ;;
        files)
            case "$action" in
                backup)
                    NAMED_ARGS["db"]=false
                    NAMED_ARGS["storage"]=true
                    NAMED_ARGS["uploads"]=true
                    NAMED_ARGS["fullbackup"]=false
                    if skip_if_dry_run "files backup"; then return 0; fi
                    ops_log_begin "backup"
                    call_with_named_args run_backup
                    ops_log_end $?
                    ;;
                prune|prune_backups|cleanup_backups)
                    if skip_if_dry_run "files prune_backups"; then return 0; fi
                    ops_log_begin "prune_backups"
                    call_with_named_args cleanup_old_backups
                    ops_log_end $?
                    ;;
                *)
                    log err "[files] Unknown action: $action"
                    return 1
                    ;;
            esac
            ;;
        self)
            case "$action" in
                install)
                    if skip_if_dry_run "self install"; then return 0; fi
                    call_with_named_args install_self
                    ;;
                update)
                    if skip_if_dry_run "self update"; then return 0; fi
                    ops_log_begin "self_update"
                    call_with_named_args self_update
                    ops_log_end $?
                    ;;
                config)
                    if skip_if_dry_run "self config"; then return 0; fi
                    call_with_named_args spawn_cli_config
                    ;;
                version)
                    call_with_named_args self_version
                    ;;
                switch-mode|switch)
                    if skip_if_dry_run "self switch-mode"; then return 0; fi
                    call_with_named_args self_switch_mode
                    ;;
                uninstall|remove)
                    if skip_if_dry_run "self uninstall"; then return 0; fi
                    call_with_named_args self_uninstall
                    ;;
                *)
                    log err "[self] Unknown action: $action"
                    return 1
                    ;;
            esac
            ;;
        env)
            case "$action" in
                show)
                    call_with_named_args env_show "${extra[@]}"
                    ;;
                get)
                    call_with_named_args env_get "${extra[@]}"
                    ;;
                set)
                    call_with_named_args env_set "${extra[@]}"
                    ;;
                unset)
                    call_with_named_args env_unset "${extra[@]}"
                    ;;
                user-ini|user_ini)
                    local sub="${extra[0]:-apply}"
                    if [[ "$sub" == "apply" ]]; then
                        call_with_named_args env_user_ini_apply "${extra[@]:1}"
                    else
                        log err "[env] Unknown user-ini action: $sub"
                        return 1
                    fi
                    ;;
                *)
                    log err "[env] Unknown action: $action"
                    return 1
                    ;;
            esac
            ;;
        cron)
            # Legacy context routed to core cron
            dispatch_command core cron "$action" "${extra[@]}"
            ;;
        update)
            # Legacy context routed to core update
            dispatch_command core update "$action" "${extra[@]}"
            ;;
        "")
            if [[ -n "$LEGACY_CMD" ]]; then
                log warn "[DISPATCH] Using legacy command: $LEGACY_CMD"
                function_caller "$LEGACY_CMD" || {
                    log err "[DISPATCH] Unknown legacy command: $LEGACY_CMD"
                    exit 1
                }
            else
                log info "No command specified. Nothing executed. Use -h for help."
            fi
            ;;
        *)
            log err "[DISPATCH] Unknown context: $ctx"
            return 1
            ;;
    esac
}

log_fallback_label() {
    local label=""
    if [[ -n "$CMD_CONTEXT" && -n "$CMD_ACTION" ]]; then
        label="${CMD_CONTEXT}:${CMD_ACTION}"
        if [[ ${#CMD_EXTRA[@]} -gt 0 && -n "${CMD_EXTRA[0]}" ]]; then
            label+=":${CMD_EXTRA[0]}"
        fi
    elif [[ -n "$LEGACY_CMD" ]]; then
        label="legacy:${LEGACY_CMD}"
    else
        label="noop"
    fi
    printf "%s" "$label"
}

# shellcheck disable=SC2034
INM_OPS_LOG_WROTE=false

if [[ -n "$CMD_CONTEXT" && -n "$CMD_ACTION" ]]; then
    if declare -F ops_log_fallback_begin >/dev/null 2>&1; then
        ops_log_fallback_begin "$(log_fallback_label)"
    fi
    rc=0
    trace_guarded=false
    if [[ "$trace_guard_dispatch" == true ]]; then
        trace_suspend && trace_guarded=true
    fi
    dispatch_command "$CMD_CONTEXT" "$CMD_ACTION" "${CMD_EXTRA[@]}" || rc=$?
    if [[ "$trace_guarded" == true ]]; then
        trace_resume
    fi
    if declare -F ops_log_fallback_end >/dev/null 2>&1; then
        ops_log_fallback_end "$rc"
    fi
    exit "$rc"
elif [[ -n "$LEGACY_CMD" ]]; then
    # Map known single-word legacy actions to contexts
    case "$LEGACY_CMD" in
        info|health) CMD_CONTEXT="core"; CMD_ACTION="health";;
        version) CMD_CONTEXT="self"; CMD_ACTION="version";;
        clear-cache|clear_cache) CMD_CONTEXT="core"; CMD_ACTION="clear-cache";;
        backup) CMD_CONTEXT="core"; CMD_ACTION="backup";;
        update) CMD_CONTEXT="core"; CMD_ACTION="update";;
        cleanup|prune) CMD_CONTEXT="core"; CMD_ACTION="prune";;
        cleanup_versions|prune_versions) CMD_CONTEXT="core"; CMD_ACTION="prune_versions";;
        cleanup_backups|prune_backups) CMD_CONTEXT="core"; CMD_ACTION="prune_backups";;
        *) ;;
    esac
    if declare -F ops_log_fallback_begin >/dev/null 2>&1; then
        ops_log_fallback_begin "$(log_fallback_label)"
    fi
    rc=0
    if [[ -n "$CMD_CONTEXT" && -n "$CMD_ACTION" ]]; then
        trace_guarded=false
        if [[ "$trace_guard_dispatch" == true ]]; then
            trace_suspend && trace_guarded=true
        fi
        dispatch_command "$CMD_CONTEXT" "$CMD_ACTION" "${CMD_EXTRA[@]}" || rc=$?
        if [[ "$trace_guarded" == true ]]; then
            trace_resume
        fi
    else
        dispatch_command "" "" || rc=$?
    fi
    if declare -F ops_log_fallback_end >/dev/null 2>&1; then
        ops_log_fallback_end "$rc"
    fi
    exit "$rc"
else
    if declare -F ops_log_fallback_begin >/dev/null 2>&1; then
        ops_log_fallback_begin "$(log_fallback_label)"
    fi
    log info "No command specified. Nothing executed. Use -h for help."
    if declare -F ops_log_fallback_end >/dev/null 2>&1; then
        ops_log_fallback_end 0
    fi
fi
