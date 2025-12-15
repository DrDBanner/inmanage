#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__CORE_CLI_LOADED:-} ]] && return
__CORE_CLI_LOADED=1

# ---------------------------------------------------------------------
# show_help()
# Basic help overview with available commands.
# ---------------------------------------------------------------------
show_help() {
    cat <<'EOF'
Usage:
  ./inmanage.sh <context> <action> [--options]
  ./inmanage.sh <legacy_command> [--options]   # still supported for compatibility

Contexts & Actions:
  core:
    install          Install Invoice Ninja
                     Options: --clean --provision --version=<v>
    update           Update Invoice Ninja
                     Options: --version=<v> --force
    backup           Full backup (db+files)
                     Options: --compress=tar.gz|zip|false --name=<label> --include-app=true|false --extra-paths=a,b
    restore          Restore from bundle
                     Options: --file=<bundle> --force --include-app=true|false --target=<path>
    health (info)    Preflight/health check
                     Options: --fast=true --skip-db=true --skip-github=true --skip-snappdf=true --skip-web-php=true
    version          Show installed/latest/cached version
    prune            Prune versions/backups/cache
    prune-versions   Prune old versions only
    prune-backups    Prune old backups only
    clear-cache      Clear app cache (artisan)
    cron install     Install cronjobs
    provision spawn  Create provision file for unattended install
    env set|get|unset|show  Manage application .env entries

  db:
    backup           DB-only backup
                     Options: --compress=tar.gz|zip|false --name=<label>
    restore          Import/restore DB
                     Options: --file=<path> --force --purge=true
    create           Create database/user
    prune            Prune old DB backups (alias to core prune-backups)

  files:
    backup           Files-only backup (storage/uploads)
                     Options: --compress=tar.gz|zip|false --name=<label>
    prune            Cleanup old file backups

  self:
    install          Install this CLI (global/local/project)
    update           Update this CLI (git pull if checkout)
    switch-mode      Reinstall in a different mode (optionally clean old)
    uninstall        Remove CLI symlinks; optionally delete install dir
  env:
    set|get|unset|show  Manage application .env keys

Legacy commands (kept, not recommended):
  Supported for compatibility; not listed here.

Global Flags:
  --force       Force operations where applicable
  --debug       Enable debug logging
  --dry-run     Log intended actions, skip execution
  -h, --help    Show this help

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
  update [--version=v] [--force]
  backup [--compress=tar.gz|zip|false] [--name=...] [--include-app=true|false] [--extra-paths=a,b]
         # Default: single full bundle (app+env+db). Flags narrow scope or add extras.
  restore --file=... [--force] [--include-app=true|false] [--target=...]
  health | info
  version
  prune | prune_versions | prune_backups
  clear-cache
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
            echo "env actions: set KEY=VAL | get KEY | unset KEY | show"
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
}
