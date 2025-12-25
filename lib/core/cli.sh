#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__CORE_CLI_LOADED:-} ]] && return
__CORE_CLI_LOADED=1

# ---------------------------------------------------------------------
# show_help()
# Basic help overview with available commands.
# ---------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage:
  ./inmanage.sh <context> <action> [--options]
  ./inmanage.sh <legacy_command> [--options]   # legacy still works

core:
  install                     Install Invoice Ninja
                              --clean --provision --version=<v>

  update                      Update Invoice Ninja
                              --version=<v> --force --cache-only

  backup                      Full backup (db+files)
                              --compress=tar.gz|zip|false --name=<label> --extra-paths=a,b

  restore                     Restore from bundle
                              --file=<bundle> --force --target=<path>
                              --autofill-missing[=1|0] --autofill-missing-app=1|0 --autofill-missing-db=1|0

  health (info)               Preflight/health check
                              --checks=TAG1,TAG2 (e.g., CLI,SYS,FS,DB,WEB,PHP,EXT,NET,APP,CRON,SNAPPDF)

  version                     Show installed/latest/cached version

  prune                       Prune versions/backups/cache
                              --override-enforced-user (skip enforced switch)
  prune-versions              Prune old versions only
  prune-backups               Prune old backups only

  clear-cache                 Clear app cache (artisan)

  cron install                Install cronjobs

  provision spawn             Create provision file
                              --provision-file=path --backup-file=path | --latest-backup

db:
  backup                      DB-only backup
                              --compress=tar.gz|zip|false --name=<label>
  restore                     Import/restore DB
                              --file=<path> --force --purge=true
  create                      Create database/user
  prune                       Prune old DB backups (alias core prune-backups)

files:
  backup                      Files-only backup (storage/uploads)
                              --compress=tar.gz|zip|false --name=<label>
  prune                       Cleanup old file backups

self:
  install                     Install this CLI (global/local/project)
  update                      Update this CLI (git pull if checkout)
  switch-mode                 Reinstall in another mode (optionally clean old)
  uninstall                   Remove CLI symlinks; optionally delete install dir

env:
  set|get|unset|show          Manage .env keys for app or cli
                              Examples:
                                env set app APP_URL https://example.test
                                env get cli INM_BASE_DIRECTORY

Legacy commands:
  Supported for compatibility; not listed here.

Global Flags:
  --force                        Force operations where applicable
  --debug                        Enable debug logging
  --dry-run                      Log intended actions, skip execution
  --override-enforced-user       Skip enforced user switch for this run
  -h, --help                     Show this help

Args:
  Pass options as --key=value.
EOF
}

# ---------------------------------------------------------------------
# show_context_help()
# Prints actions for a given context.
# ---------------------------------------------------------------------
show_context_help() {
    local ctx="$1"
    case "$ctx" in
        core)
            cat <<'EOF'
core actions:
  install [--clean] [--provision] [--version=v]
  update [--version=v] [--force] [--cache-only]
  backup [--compress=tar.gz|zip|false] [--name=...] [--include-app=true|false] [--extra-paths=a,b]
         # Default: single full bundle (app+env+db). Flags narrow scope or add extras.
  restore --file=... [--force] [--include-app=true|false] [--target=...]
  health | info
  version
  prune [--override-enforced-user] | prune_versions | prune_backups
  clear-cache
  provision spawn [--provision-file=path] [--backup-file=path|--latest-backup]
EOF
            ;;
        db)
            cat <<'EOF'
db actions:
  backup [--compress=tar.gz|zip|false] [--name=...]
  restore --file=path [--force] [--purge=true]
  create
EOF
            ;;
        files)
            cat <<'EOF'
files actions:
  backup [--compress=tar.gz|zip|false] [--name=...]
  prune
EOF
            ;;
        self)
            cat <<'EOF'
self actions:
  install
  update
  switch-mode    # reinstall in another mode; optionally clean old install/symlinks
  uninstall      # remove symlinks; optionally delete install dir
EOF
            ;;
        env)
            cat <<'EOF'
env actions:
  set <app|cli> KEY VALUE
  get <app|cli> KEY
  unset <app|cli> KEY
  show [app|cli]
EOF
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
#   force_update, DEBUG, SHOW_FUNCTION_HELP, NAMED_ARGS.
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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                # shellcheck disable=SC2034
                SHOW_FUNCTION_HELP=true
                shift
                continue
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
            --dry-run)
                # shellcheck disable=SC2034
                DRY_RUN=true
                ;;
            --override_enforced_user)
                NAMED_ARGS[override_enforced_user]=true
                ;;
            --override-enforced-user)
                NAMED_ARGS[override_enforced_user]=true
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

    # Subcommand detection
    if [[ ${#positionals[@]} -ge 2 ]]; then
        CMD_CONTEXT="${positionals[0]}"
        CMD_ACTION="${positionals[1]}"
        CMD_EXTRA=("${positionals[@]:2}")
    elif [[ ${#positionals[@]} -eq 1 ]]; then
        # Legacy single-word command
        LEGACY_CMD="${positionals[0]}"
    fi

    # Export well-known flags so downstream helpers see them
    export DEBUG DRY_RUN force_update
    if [[ "${NAMED_ARGS[override_enforced_user]:-}" == "true" ]]; then
        export INM_OVERRIDE_ENFORCED_USER=true
    fi
}
