#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__INSTALL_OUTPUT_HELPER_LOADED:-} ]] && return
__INSTALL_OUTPUT_HELPER_LOADED=1

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

print_cron_manual_instructions() {
    local jobs="${1:-artisan}"
    local user="${2:-$INM_ENFORCED_USER}"
    local cli_cmd
    cli_cmd="$(install_cli_hint)"
    local base_clean="${INM_BASE_DIRECTORY%/}"

    printf "%bCron install failed.%b\n" "$MAGENTA" "$RESET"
    cron_jobs_flags "$jobs"
    printf "Try: %b%s core cron install --user=%s --jobs=%s%b\n" "$CYAN" "$cli_cmd" "$user" "$jobs" "$RESET"
    printf "Or add to %b/etc/cron.d/invoiceninja%b (root):\n" "$CYAN" "$RESET"
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

print_provisioned_summary() {
    local cron_ok="${1:-false}"
    local cron_jobs="${2:-both}"
    local cron_skipped="${3:-false}"
    local app_url="${APP_URL:-https://your.url}"
    local provision_file="${INM_PROVISION_FILE_USED:-${INM_PROVISION_ENV_FILE:-.inmanage/.env.provision}}"
    if [[ "$provision_file" != /* ]]; then
        if [[ -n "${INM_BASE_DIRECTORY:-}" ]]; then
            provision_file="${INM_BASE_DIRECTORY%/}/${provision_file#/}"
        else
            provision_file="$(pwd)/${provision_file#/}"
        fi
    fi

    printf "\n%b%s%b\n" "$BLUE" "========================================" "$RESET"
    printf "%b%bSetup Complete!%b\n\n" "$GREEN" "$BOLD" "$RESET"
    printf "%bLogin:%b %b%s%b\n" "$BOLD" "$RESET" "$CYAN" "$app_url" "$RESET"
    printf "%bUsername:%b admin@admin.com\n" "$BOLD" "$RESET"
    printf "%bPassword:%b admin [change that ;-) *you're not goofy]\n" "$BOLD" "$RESET"
    printf "%b%s%b\n\n" "$BLUE" "========================================" "$RESET"
    printf "%bOpen your browser at %b%s%b to access the application.%b\n" "$WHITE" "$CYAN" "$app_url" "$RESET" "$RESET"
    printf "The database and user are configured.\n\n"
    printf "%bIt's a good time to make your first backup now!%b\n\n" "$YELLOW" "$RESET"
    local installed_jobs="${INM_CRON_INSTALLED_JOBS:-$cron_jobs}"
    local cron_target="${INM_CRON_INSTALL_TARGET:-}"

    if [[ "$cron_skipped" == true ]]; then
        printf "%bCron install skipped (--no-cron-install).%b\n\n" "$YELLOW" "$RESET"
    elif [[ "$cron_ok" == true ]]; then
        local summary
        summary="$(cron_jobs_summary "$installed_jobs")"
        printf "%bCron installed (%s).%b\n" "$GREEN" "$summary" "$RESET"
        if [[ -n "$cron_target" ]]; then
            printf "%bTarget:%b %s\n\n" "$WHITE" "$RESET" "$cron_target"
        else
            printf "\n"
        fi
    else
        print_cron_manual_instructions "$cron_jobs" "${INM_ENFORCED_USER:-$(whoami)}"
    fi
    printf "%b%bYour provision file must get removed manually once you are satisfied.%b\n" "$MAGENTA" "$BOLD" "$RESET"
    printf "Delete %b%s%b since it has sensitive data stored.\n\n" "$CYAN" "$provision_file" "$RESET"
}

print_wizard_summary() {
    local cron_ok="${1:-false}"
    local cron_jobs="${2:-artisan}"
    local cron_skipped="${3:-false}"
    local setup_url="https://your.url/setup"
    if [[ -n "${APP_URL:-}" ]]; then
        setup_url="${APP_URL%/}/setup"
    fi

    printf "\n%b%s%b\n" "$BLUE" "========================================" "$RESET"
    printf "%b%bSetup Complete!%b\n\n" "$GREEN" "$BOLD" "$RESET"
    printf "%bOpen your browser at your configured address %b%s%b to complete database setup.%b\n\n" "$WHITE" "$CYAN" "$setup_url" "$RESET" "$RESET"
    printf "%bIt's a good time to make your first backup now!%b\n\n" "$YELLOW" "$RESET"
    local installed_jobs="${INM_CRON_INSTALLED_JOBS:-$cron_jobs}"
    local cron_target="${INM_CRON_INSTALL_TARGET:-}"

    if [[ "$cron_skipped" == true ]]; then
        printf "%bCron install skipped (--no-cron-install).%b\n\n" "$YELLOW" "$RESET"
    elif [[ "$cron_ok" == true ]]; then
        local summary
        summary="$(cron_jobs_summary "$installed_jobs")"
        printf "%bCron installed (%s).%b\n" "$GREEN" "$summary" "$RESET"
        if [[ -n "$cron_target" ]]; then
            printf "%bTarget:%b %s\n\n" "$WHITE" "$RESET" "$cron_target"
        else
            printf "\n"
        fi
    else
        print_cron_manual_instructions "$cron_jobs" "${INM_ENFORCED_USER:-$(whoami)}"
    fi
}
