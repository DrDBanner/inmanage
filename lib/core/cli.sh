#!/usr/bin/env bash

# ---------------------------------------------------------------------
# Core module: cli.sh
# Scope: help/usage rendering + docs extraction.
# Avoid: runtime actions; services execute operations.
# Provides: CLI help and docs lookup.
# ---------------------------------------------------------------------

# Prevent double sourcing
[[ -n ${__CORE_CLI_LOADED:-} ]] && return
__CORE_CLI_LOADED=1

# ---------------------------------------------------------------------
# show_help()
# Basic help overview with available commands.
# ---------------------------------------------------------------------

# TODO: AS/400-style shell interface for Invoice Ninja? Depends on community engagement; heavy lift. Would enable a complete UI on shell;

cli_docs_index_path() {
    if [ -n "${INM_DOCS_INDEX:-}" ]; then
        printf "%s" "$INM_DOCS_INDEX"
        return 0
    fi
    local script_root
    script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    printf "%s" "${script_root%/}/docs/index.md"
}

cli_help_from_docs() {
    local id="$1"
    local docs
    docs="$(cli_docs_index_path)"
    [ -f "$docs" ] || return 1
    awk -v id="$id" '
        $0 ~ "^[[:space:]]*<!-- CLI_HELP:" id "[[:space:]]*-->" { in_block=1; next }
        $0 ~ "^[[:space:]]*<!-- END_CLI_HELP -->" { if (in_block) exit }
        in_block {
            if ($0 ~ /^```/) next
            sub(/\r$/, "")
            print
        }
    ' "$docs"
}

cli_print_help() {
    local id="$1"
    local fallback="${2:-}"
    if cli_help_from_docs "$id"; then
        return 0
    fi
    if [ -n "$fallback" ] && cli_help_from_docs "$fallback"; then
        return 0
    fi
    printf "Help text not found in docs (id=%s).\n" "$id"
    printf "Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md\n"
    return 0
}

show_help() {
    cli_print_help "top"
}

# ---------------------------------------------------------------------
# show_context_help()
# Prints actions for a given context.
# ---------------------------------------------------------------------
show_context_help() {
    local ctx="$1"
    case "$ctx" in
        core)
            cli_print_help "core" "top"
            ;;
        spawn)
            cli_print_help "spawn" "top"
            ;;
        db)
            cli_print_help "db" "top"
            ;;
        files)
            cli_print_help "files" "top"
            ;;
        self)
            cli_print_help "self" "top"
            ;;
        env)
            cli_print_help "env" "top"
            ;;
        *)
            show_help
            ;;
    esac
}

# ---------------------------------------------------------------------
# show_action_help()
# Prints help for a specific context/action combo.
# ---------------------------------------------------------------------
show_action_help() {
    local ctx="$1"
    local action="$2"
    local action_norm
    action_norm="${action//_/-}"
    case "$ctx" in
        core)
            if [[ "$action_norm" == "info" ]]; then
                action_norm="health"
            fi
            cli_print_help "core-${action_norm}" "core"
            ;;
        db)
            cli_print_help "db-${action_norm}" "db"
            ;;
        files)
            cli_print_help "files-${action_norm}" "files"
            ;;
        self)
            case "$action_norm" in
                config)
                    cli_print_help "self-config" "self"
                    ;;
                install|update|switch-mode|uninstall|version)
                    cli_print_help "self-commands" "self"
                    ;;
                *)
                    show_context_help "$ctx"
                    ;;
            esac
            ;;
        env)
            case "$action_norm" in
                set|get|unset|show|user-ini|user-ini-apply)
                    cli_print_help "env-commands" "env"
                    ;;
                *)
                    show_context_help "$ctx"
                    ;;
            esac
            ;;
        spawn)
            cli_print_help "spawn" "top"
            ;;
        *)
            show_help
            ;;
    esac
}

# ---------------------------------------------------------------------
# show_function_help()
# Simple alias to show_help until per-command docs exist.
# ---------------------------------------------------------------------
show_function_help() {
    show_help
}

# ---------------------------------------------------------------------
# parse_options()
# Parses CLI args, sets globals:
#   CMD_CONTEXT, CMD_ACTION, CMD_EXTRA (positional tail), LEGACY_CMD,
#   force_update, DEBUG, DEBUG_LEVEL, SHOW_FUNCTION_HELP, NAMED_ARGS.
# Recognizes subcommands and legacy commands; leaves --key=value in NAMED_ARGS.
# ---------------------------------------------------------------------
parse_options() {
    # shellcheck disable=SC2034
    declare -g -A NAMED_ARGS=()
    parse_named_args NAMED_ARGS "$@"

    SHOW_FUNCTION_HELP=false
    CMD_CONTEXT=""
    CMD_ACTION=""
    CMD_EXTRA=()
    LEGACY_CMD=""

    local positionals=()
    local version_only=false
    local debug_level_arg="${NAMED_ARGS[debuglevel]:-${NAMED_ARGS[debug_level]:-}}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                # shellcheck disable=SC2034
                SHOW_FUNCTION_HELP=true
                shift
                continue
                ;;
            -v)
                version_only=true
                ;;
            --no-cli-clear)
                NAMED_ARGS[no_cli_clear]=true
                # shellcheck disable=SC2034
                NO_CLI_CLEAR=true
                ;;
            --force)
                # shellcheck disable=SC2034
                force_update=true
                ;;
            --clean)
                NAMED_ARGS[clean]=true
                # shellcheck disable=SC2034
                force_update=true
                ;;
            --provision)
                NAMED_ARGS[provision]=true
                ;;
            --debug)
                # shellcheck disable=SC2034
                DEBUG=true
                ;;
            --debuglevel|--debug-level)
                if [[ -n "${2:-}" && "$2" != --* ]]; then
                    debug_level_arg="$2"
                    NAMED_ARGS[debuglevel]="$2"
                    shift
                else
                    debug_level_arg="1"
                    NAMED_ARGS[debuglevel]="1"
                fi
                ;;
            --dry-run)
                # shellcheck disable=SC2034
                DRY_RUN=true
                ;;
            --override_enforced_user)
                NAMED_ARGS["override_enforced_user"]=true
                ;;
            --override-enforced-user)
                NAMED_ARGS["override_enforced_user"]=true
                ;;
            *)
                # Only treat as positional if it is not an option (starts with -- or -)
                if [[ "$1" != --* && "$1" != -* ]]; then
                    positionals+=("$1")
                fi
                ;;
        esac
        shift
    done

    if [[ -n "$debug_level_arg" ]]; then
        case "${debug_level_arg,,}" in
            true|yes|on) debug_level_arg="1" ;;
        esac
        if [[ "$debug_level_arg" =~ ^[0-9]+$ ]]; then
            if [ "$debug_level_arg" -gt 2 ]; then
                debug_level_arg="2"
            fi
        else
            debug_level_arg="1"
        fi
        if [ "$debug_level_arg" -gt 0 ]; then
            DEBUG=true
        else
            DEBUG=false
        fi
        DEBUG_LEVEL="$debug_level_arg"
        NAMED_ARGS[debuglevel]="$debug_level_arg"
        unset 'NAMED_ARGS[debug_level]'
    else
        if [ "$DEBUG" = true ]; then
            DEBUG_LEVEL=1
        elif [[ -z "${DEBUG_LEVEL:-}" ]]; then
            DEBUG_LEVEL=0
        fi
    fi

    # Subcommand detection
    if [[ ${#positionals[@]} -ge 2 ]]; then
        # shellcheck disable=SC2034
        CMD_CONTEXT="${positionals[0]}"
        # shellcheck disable=SC2034
        CMD_ACTION="${positionals[1]}"
        # shellcheck disable=SC2034
        CMD_EXTRA=("${positionals[@]:2}")
    elif [[ ${#positionals[@]} -eq 1 ]]; then
        case "${positionals[0]}" in
            core|db|files|env|self|spawn)
                # Show context help when only a context is provided.
                # shellcheck disable=SC2034
                CMD_CONTEXT="${positionals[0]}"
                # shellcheck disable=SC2034
                SHOW_FUNCTION_HELP=true
                ;;
            *)
                # Legacy single-word command
                # shellcheck disable=SC2034
                LEGACY_CMD="${positionals[0]}"
                ;;
        esac
    elif [[ "$version_only" == true ]]; then
        # shellcheck disable=SC2034
        CMD_CONTEXT="self"
        # shellcheck disable=SC2034
        CMD_ACTION="version"
        # shellcheck disable=SC2034
        LEGACY_CMD="version"
    fi

    # Export well-known flags so downstream helpers see them
    export DEBUG DRY_RUN force_update
    export NO_CLI_CLEAR
    if [[ "${NAMED_ARGS[override_enforced_user]:-}" == "true" ]]; then
        export INM_OVERRIDE_ENFORCED_USER=true
    fi
}
