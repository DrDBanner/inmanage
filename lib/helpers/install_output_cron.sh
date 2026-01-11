#!/usr/bin/env bash

# ---------------------------------------------------------------------
# install_cli_hint()
# Resolve the CLI command name for user-facing output.
# Consumes: env: SCRIPT_NAME, SCRIPT_PATH.
# Computes: best CLI command string.
# Returns: prints command string to stdout.
# ---------------------------------------------------------------------
install_cli_hint() {
    local cmd=""
    if [[ "$SCRIPT_NAME" == "inmanage" || "$SCRIPT_NAME" == "inm" ]]; then
        cmd="$SCRIPT_NAME"
    elif [[ "$SCRIPT_PATH" == */* ]]; then
        cmd="$SCRIPT_PATH"
    else
        cmd="./$SCRIPT_NAME"
    fi
    printf "%s" "$cmd"
}

# ---------------------------------------------------------------------
# cron_jobs_flags()
# Parse cron job list into CRON_JOB_* flags.
# Consumes: args: raw job list.
# Computes: CRON_JOB_ARTISAN / CRON_JOB_BACKUP / CRON_JOB_HEARTBEAT globals.
# Returns: 0 after setting flags.
# ---------------------------------------------------------------------
cron_jobs_flags() {
    local raw="$1"
    CRON_JOB_ARTISAN=false
    CRON_JOB_BACKUP=false
    CRON_JOB_HEARTBEAT=false
    raw="${raw,,}"
    IFS=',' read -ra parts <<<"$raw"
    local part
    for part in "${parts[@]}"; do
        case "$part" in
            scheduler|schedule|artisan|artisan:scheduler)
                CRON_JOB_ARTISAN=true
                ;;
            backup)
                CRON_JOB_BACKUP=true
                ;;
            heartbeat)
                CRON_JOB_HEARTBEAT=true
                ;;
            both|essential)
                CRON_JOB_ARTISAN=true
                CRON_JOB_BACKUP=true
                ;;
            all)
                CRON_JOB_ARTISAN=true
                CRON_JOB_BACKUP=true
                CRON_JOB_HEARTBEAT=true
                ;;
        esac
    done
    if [[ "$CRON_JOB_ARTISAN" != true && "$CRON_JOB_BACKUP" != true && "$CRON_JOB_HEARTBEAT" != true ]]; then
        CRON_JOB_ARTISAN=true
        CRON_JOB_BACKUP=true
    fi
}

# ---------------------------------------------------------------------
# cron_jobs_summary()
# Build a human-readable summary for cron jobs.
# Consumes: args: raw job list; deps: cron_jobs_flags.
# Computes: summary string.
# Returns: prints summary to stdout.
# ---------------------------------------------------------------------
cron_jobs_summary() {
    local raw="$1"
    cron_jobs_flags "$raw"
    local summary=""
    if [[ "$CRON_JOB_ARTISAN" == true ]]; then
        summary="artisan"
    fi
    if [[ "$CRON_JOB_BACKUP" == true ]]; then
        summary="${summary:+${summary} + }backup"
    fi
    if [[ "$CRON_JOB_HEARTBEAT" == true ]]; then
        summary="${summary:+${summary} + }heartbeat"
    fi
    printf "%s" "${summary:-none}"
}

# ---------------------------------------------------------------------
# print_cron_manual_instructions()
# Print manual cron installation instructions.
# Consumes: args: jobs, user; env: INM_BASE_DIRECTORY, INM_CRON_BACKUP_TIME, INM_NOTIFY_HEARTBEAT_TIME, INM_ENFORCED_SHELL.
# Computes: cron command lines for selected jobs.
# Returns: 0 after printing.
# ---------------------------------------------------------------------
print_cron_manual_instructions() {
    local jobs="${1:-artisan}"
    local user="${2:-$INM_ENFORCED_USER}"
    local cli_cmd
    cli_cmd="$(install_cli_hint)"
    local base_clean="${INM_BASE_DIRECTORY%/}"
    local instance_id
    instance_id="$(env_resolve_instance_id "$base_clean" "${INM_ENV_FILE:-}")"

    printf "%bCron install failed.%b\n" "$MAGENTA" "$RESET"
    cron_jobs_flags "$jobs"
    printf "Try: %b%s core cron install --user=%s --jobs=%s%b\n" "$CYAN" "$cli_cmd" "$user" "$jobs" "$RESET"
    printf "Or add to %b/etc/cron.d/inmanage-%s%b (root):\n" "$CYAN" "$instance_id" "$RESET"
    if [[ "$CRON_JOB_ARTISAN" == true ]]; then
        printf "  %b* * * * * %s %s schedule:run >> /dev/null 2>&1%b\n" "$CYAN" "$user" "$(artisan_cmd_string)" "$RESET"
    fi
    local backup_time="${INM_CRON_BACKUP_TIME:-03:24}"
    local backup_hour="03"
    local backup_min="24"
    if [[ "$backup_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        backup_hour="${backup_time%:*}"
        backup_min="${backup_time#*:}"
    fi
    if [[ "$CRON_JOB_BACKUP" == true ]]; then
        printf "  %b%s %s * * * %s %s -c \"%s/inmanage core backup\" >> /dev/null 2>&1%b\n" \
            "$CYAN" "$backup_min" "$backup_hour" "$user" "$INM_ENFORCED_SHELL" "$base_clean" "$RESET"
    fi
    if [[ "$CRON_JOB_HEARTBEAT" == true ]]; then
        local heartbeat_time="${INM_NOTIFY_HEARTBEAT_TIME:-06:00}"
        local heartbeat_hour="06"
        local heartbeat_min="00"
        if [[ "$heartbeat_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            heartbeat_hour="${heartbeat_time%:*}"
            heartbeat_min="${heartbeat_time#*:}"
        fi
        printf "  %b%s %s * * * %s %s -c \"%s/inmanage core health --notify-heartbeat\" >> /dev/null 2>&1%b\n" \
            "$CYAN" "$heartbeat_min" "$heartbeat_hour" "$user" "$INM_ENFORCED_SHELL" "$base_clean" "$RESET"
    fi
    printf "\n"
}
