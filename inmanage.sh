#!/usr/bin/env bash
set -e

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

if [ -f "${LIB_DIR}/helpers/env_read.sh" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/helpers/env_read.sh"
else
    echo "[ERR] Missing env read helper: ${LIB_DIR}/helpers/env_read.sh" >&2
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
if [ "$DEBUG" = true ]; then
    log debug "[BOOT] Loaded modules from $LIB_DIR (env,args,prompt,selection,fs,user,resolve,cli,config,checks,services)"
fi
# TODO: Align README command list with actual commands if they drift again.

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
    spawn_provision)
        spawn_provision_file
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
CMD_CONTEXT=""
CMD_ACTION=""
SHOW_FUNCTION_HELP=false
DRY_RUN=false

parse_options "$@"

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
                [[ "${NAMED_ARGS[clean]:-false}" == true ]] && force_update=true
                local mode=""
                    [[ "${NAMED_ARGS[provision]:-false}" == true ]] && mode="Provisioned"
                    if skip_if_dry_run "core install"; then return 0; fi
                    call_with_named_args run_installation "$mode"
                    ;;
            update)
                local sub="${extra[0]:-}"
                if [[ "$sub" == "rollback" ]]; then
                    if skip_if_dry_run "core update rollback"; then return 0; fi
                    call_with_named_args run_update_rollback "${extra[1]:-}"
                else
                    if skip_if_dry_run "core update"; then return 0; fi
                    call_with_named_args run_update
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
            backup)
                NAMED_ARGS["fullbackup"]=true
                if skip_if_dry_run "core backup"; then return 0; fi
                call_with_named_args run_backup
                ;;
            restore)
                if skip_if_dry_run "core restore"; then return 0; fi
                call_with_named_args run_restore
                ;;
            cron)
                local sub="${extra[0]:-install}"
                if [[ "$sub" == "install" ]]; then
                    if skip_if_dry_run "core cron install"; then return 0; fi
                    call_with_named_args install_cronjob
                elif [[ "$sub" == "uninstall" || "$sub" == "remove" ]]; then
                    if skip_if_dry_run "core cron uninstall"; then return 0; fi
                    call_with_named_args uninstall_cronjob
                else
                    log err "[core] Unknown cron action: $sub"
                    return 1
                fi
                ;;
            provision)
                local sub="${extra[0]:-spawn}"
                if [[ "$sub" == "spawn" ]]; then
                    if skip_if_dry_run "core provision spawn"; then return 0; fi
                    call_with_named_args spawn_provision_file
                else
                    log err "[core] Unknown provision action: $sub"
                    return 1
                fi
                ;;
            prune)
                if skip_if_dry_run "core cleanup"; then return 0; fi
                call_with_named_args cleanup
                ;;
            prune_versions|prune-versions|clean_versions|clean-versions)
                    if skip_if_dry_run "core cleanup_versions"; then return 0; fi
                    call_with_named_args cleanup_old_versions
                    ;;
                prune_backups|prune-backups|clean_backups|clean-backups)
                    if skip_if_dry_run "core cleanup_backups"; then return 0; fi
                    call_with_named_args cleanup_old_backups
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
        db)
            case "$action" in
                backup)
                    NAMED_ARGS["db"]=true
                    NAMED_ARGS["fullbackup"]=false
                    NAMED_ARGS["include_app"]=false
                    NAMED_ARGS["storage"]=false
                    NAMED_ARGS["uploads"]=false
                    if skip_if_dry_run "db backup"; then return 0; fi
                    call_with_named_args run_backup
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
                    call_with_named_args cleanup_old_backups
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
                    call_with_named_args run_backup
                    ;;
                prune|prune_backups|cleanup_backups)
                    if skip_if_dry_run "files prune_backups"; then return 0; fi
                    call_with_named_args cleanup_old_backups
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
                    call_with_named_args self_update
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
        provision)
            # Legacy context routed to core provision
            dispatch_command core provision "$action" "${extra[@]}"
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

if [[ -n "$CMD_CONTEXT" && -n "$CMD_ACTION" ]]; then
    dispatch_command "$CMD_CONTEXT" "$CMD_ACTION" "${CMD_EXTRA[@]}"
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
    if [[ -n "$CMD_CONTEXT" && -n "$CMD_ACTION" ]]; then
        dispatch_command "$CMD_CONTEXT" "$CMD_ACTION" "${CMD_EXTRA[@]}"
    else
        dispatch_command "" ""
    fi
else
    log info "No command specified. Nothing executed. Use -h for help."
fi
