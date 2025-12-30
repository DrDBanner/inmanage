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
                              --cron-mode=auto|system|crontab --no-cron-install
                              --cron-jobs=artisan|backup|heartbeat|essential|both|all --no-backup-cron --backup-time=HH:MM --heartbeat-time=HH:MM
                              --bypass-check-sha
                              Provisioned install is recommended (uses .inmanage/.env.provision; create with core provision spawn)

  update                      Update Invoice Ninja
                              --version=<v> --force --cache-only --no-db-backup --preserve-paths=a,b
                              --bypass-check-sha
                              rollback [last|<dir>]

  backup                      Full backup (db+files)
                              --compress=tar.gz|zip|false --name=<label> --extra-paths=a,b|--extra=a,b
                              --create-migration-export

  restore                     Restore from bundle
                              --file=<bundle> --force --target=<path>
                              --autofill-missing[=1|0] --autofill-missing-app=1|0 --autofill-missing-db=1|0
                              --latest --auto-select=true|false

  health (info)               Preflight/health check
                              --checks=TAG1,TAG2 --check=TAG1,TAG2 --exclude=TAG1,TAG2 --fix-permissions
                              --notify-test --notify-heartbeat
                              (e.g., CLI,SYS,FS,DB,WEB,PHP,EXT,NET,APP,CRON,SNAPPDF)

  versions                    Show installed/latest/cached app versions

  prune                       Prune versions/backups/cache
                              --override-enforced-user (skip enforced switch)
  prune-versions              Prune old versions only
  prune-backups               Prune old backups only

  clear-cache                 Clear app cache (artisan)

  cron install|uninstall      Install or remove cronjobs

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
                              --compress=tar.gz|zip|false --name=<label> --include-app=true|false
                              --extra-paths=a,b|--extra=a,b
  prune                       Cleanup old file backups

self:
  install                     Install this CLI (global/local/project)
  update                      Update this CLI (git pull if checkout)
  version                     Show CLI version/metadata
  switch-mode                 Reinstall in another mode (optionally clean old)
  uninstall                   Remove CLI symlinks; optionally delete install dir

env:
  set|get|unset|show          Manage .env keys for app or cli
                              Examples:
                                env set app APP_URL https://example.test
                                env get cli INM_BASE_DIRECTORY
  user-ini apply [path]       Write recommended .user.ini (defaults to app public/)

Legacy commands:
  Supported for compatibility; not listed here.

Global Flags:
  --force                        Force operations where applicable
  --debug                        Enable debug logging
  --dry-run                      Log intended actions, skip execution
  --override-enforced-user       Skip enforced user switch for this run
  --no-cli-clear                 Skip clearing terminal and logo output
  --ninja-location=path          Use a specific app directory (must contain .env)
  --config=path                  Use a specific CLI config file (.env.inmanage)
  --config-root=dir              Override CLI config directory root (default .inmanage)
  --auto-create-config=true|false Auto-persist derived CLI config when missing
  --auto-select=true|false       Auto-select defaults when no TTY is available
  --select-timeout=secs          Timeout for interactive selections (seconds)
  -v                            Show CLI version (alias: self version)
  -h, --help                     Show this help

Args:
  Pass options as --key=value.

Docs:
  https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
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
  install [--clean] [--provision] [--version=v] [--bypass-check-sha]
         # Provisioned install is recommended; wizard install only when needed.
  update [--version=v] [--force] [--cache-only] [--no-db-backup] [--preserve-paths=a,b] [--bypass-check-sha]
         rollback [last|<dir>]
  backup [--compress=tar.gz|zip|false] [--name=...] [--include-app=true|false] [--extra-paths=a,b]
         [--create-migration-export] [--extra=a,b]
         # Default: single full bundle (app+env+db). Flags narrow scope or add extras.
  restore --file=... [--force] [--include-app=true|false] [--target=...] [--latest] [--auto-select=true|false]
         # DB import requires --force.
  health | info [--checks=TAG1,TAG2] [--check=TAG1,TAG2] [--exclude=TAG1,TAG2] [--fix-permissions]
         [--notify-test] [--notify-heartbeat]
  versions
  prune [--override-enforced-user] | prune_versions | prune_backups
  clear-cache
  cron install|uninstall [--user=name] [--jobs=artisan|backup|heartbeat|essential|both|all]
                        [--mode=auto|system|crontab] [--backup-time=HH:MM] [--heartbeat-time=HH:MM]
                        [--create-test-job] [--remove-test-job]
  provision spawn [--provision-file=path] [--backup-file=path|--latest-backup]
EOF
            ;;
        db)
            cat <<'EOF'
db actions:
  backup [--compress=tar.gz|zip|false] [--name=...]
  restore --file=path [--force] [--purge=true]
         # Requires --force (destructive).
  purge --force
         # Drops all tables in the current DB (no drop/create).
  create
EOF
            ;;
        files)
            cat <<'EOF'
files actions:
  backup [--compress=tar.gz|zip|false] [--name=...] [--include-app=true|false]
         [--bundle=true|false] [--storage=true|false] [--uploads=true|false]
         [--extra-paths=a,b] [--extra=a,b]
  prune
EOF
            ;;
        self)
            cat <<'EOF'
self actions:
  install [--install-owner=USER:GROUP] [--install-perms=DIR:FILE]
  update
  version
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
  user-ini apply [path]
EOF
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
    case "$ctx" in
        core)
            case "$action" in
                install)
                    cat <<'EOF'
core install:
  inm core install [--clean] [--provision] [--version=v]
  - Recommended: provisioned install (uses .inmanage/.env.provision)
  - Create provision file first: inm core provision spawn
  - Wizard install only if you need the interactive web setup
  - Provisioned installs require --force (destructive)
  - Optional: --no-backup to skip pre-provision DB backup
  - Optional: --no-cron-install to skip cron setup
  - Optional: --cron-mode=auto|system|crontab to force cron install mode
  - Optional: --cron-jobs=artisan|backup|heartbeat|essential|both|all to override installed cron jobs
  - Optional: --no-backup-cron to skip the backup cron job
  - Optional: --backup-time=HH:MM for the backup cron schedule (default 03:24)
  - Optional: --heartbeat-time=HH:MM for the heartbeat cron schedule (default 06:00)
  - Optional: --bypass-check-sha to skip release digest verification (not recommended)
  - Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                update)
                    cat <<'EOF'
core update:
  inm core update [--version=v] [--force] [--cache-only] [--no-db-backup]
                      [--preserve-paths=a,b] [--bypass-check-sha]
  inm core update rollback [last|<dir>]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                backup)
                    cat <<'EOF'
core backup:
  inm core backup [--compress=tar.gz|zip|false] [--name=...] [--include-app=true|false]
                       [--bundle=true|false] [--db=true|false] [--storage=true|false] [--uploads=true|false]
                       [--fullbackup=true|false] [--extra-paths=a,b] [--extra=a,b]
                       [--create-migration-export]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                restore)
                    cat <<'EOF'
core restore:
  inm core restore --file=... [--force] [--include-app=true|false] [--target=...]
  --autofill-missing[=1|0] --autofill-missing-app=1|0 --autofill-missing-db=1|0
  --latest --auto-select=true|false
  - DB import requires --force
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                health|info)
                    cat <<'EOF'
core health (info):
  inm core health [--checks=TAG1,TAG2] [--check=TAG1,TAG2] [--exclude=TAG1,TAG2] [--fix-permissions]
                       [--no-cli-clear]
  Tags: CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,MAIL,DB,APP,CRON,SNAPPDF
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                version)
                    cat <<'EOF'
core version:
  inm core version
  - Deprecated: use "inm core versions"

  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                versions)
                    cat <<'EOF'
core versions:
  inm core versions
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                prune)
                    cat <<'EOF'
core prune:
  inm core prune [--override-enforced-user]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                prune_versions|prune-versions)
                    cat <<'EOF'
core prune-versions:
  inm core prune-versions
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                prune_backups|prune-backups)
                    cat <<'EOF'
core prune-backups:
  inm core prune-backups
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                cron)
                    cat <<'EOF'
core cron install:
  inm core cron install [--user=name] [--jobs=artisan|backup|both]
                             [--mode=auto|system|crontab] [--cron-file=path]
                             [--backup-time=HH:MM] [--create-test-job]
  inm core cron uninstall [--mode=auto|system|crontab] [--cron-file=path] [--remove-test-job]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                clear-cache|clear_cache)
                    cat <<'EOF'
core clear-cache:
  inm core clear-cache
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                provision)
                    cat <<'EOF'
core provision spawn:
  inm core provision spawn [--provision-file=path] [--backup-file=path|--latest-backup]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                *)
                    show_context_help "$ctx"
                    ;;
            esac
            ;;
        db)
            case "$action" in
                backup)
                    cat <<'EOF'
db backup:
  inm db backup [--compress=tar.gz|zip|false] [--name=...]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                restore)
                    cat <<'EOF'
db restore:
  inm db restore --file=path [--force] [--purge=true]
  - Requires --force (destructive)
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                purge)
                    cat <<'EOF'
db purge:
  inm db purge --force
  - Drops all tables/views in the current DB (destructive)
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                create)
                    cat <<'EOF'
db create:
  inm db create [--db-host=host] [--db-port=port] [--db-name=name]
                     [--db-user=user] [--db-pass=pass]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                *)
                    show_context_help "$ctx"
                    ;;
            esac
            ;;
        files)
            case "$action" in
                backup)
                    cat <<'EOF'
files backup:
  inm files backup [--compress=tar.gz|zip|false] [--name=...] [--include-app=true|false]
                        [--bundle=true|false] [--storage=true|false] [--uploads=true|false]
                        [--extra-paths=a,b] [--extra=a,b]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                prune)
                    cat <<'EOF'
files prune:
  inm files prune
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                *)
                    show_context_help "$ctx"
                    ;;
            esac
            ;;
        self)
            case "$action" in
                install|update|switch-mode|switch_mode|uninstall|version)
                    cat <<'EOF'
self commands:
  inm self install
  inm self update
  inm self version
  inm self switch-mode
  inm self uninstall
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                *)
                    show_context_help "$ctx"
                    ;;
            esac
            ;;
        env)
            case "$action" in
                set|get|unset|show)
                    cat <<'EOF'
env commands:
  inm env set <app|cli> KEY VALUE
  inm env get <app|cli> KEY
  inm env unset <app|cli> KEY
  inm env show [app|cli]
  inm env user-ini apply [path]
  
  Docs: https://github.com/DrDBanner/inmanage/blob/main/docs/index.md
EOF
                    ;;
                *)
                    show_context_help "$ctx"
                    ;;
            esac
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
    local version_only=false

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
            core|db|files|env|self)
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
        LEGACY_CMD="version"
    fi

    # Export well-known flags so downstream helpers see them
    export DEBUG DRY_RUN force_update
    export NO_CLI_CLEAR
    if [[ "${NAMED_ARGS[override_enforced_user]:-}" == "true" ]]; then
        export INM_OVERRIDE_ENFORCED_USER=true
    fi
}
