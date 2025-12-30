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

    printf "${MAGENTA}Cron install failed.${RESET}\n"
    cron_jobs_flags "$jobs"
    printf "Try: ${CYAN}%s core cron install --user=%s --jobs=%s${RESET}\n" "$cli_cmd" "$user" "$jobs"
    printf "Or add to ${CYAN}/etc/cron.d/invoiceninja${RESET} (root):\n"
    if [[ "$CRON_JOB_ARTISAN" == true ]]; then
        printf "  ${CYAN}* * * * * %s %s schedule:run >> /dev/null 2>&1${RESET}\n" "$user" "$(artisan_cmd_string)"
    fi
    local backup_time="${INM_CRON_BACKUP_TIME:-03:24}"
    local backup_hour="03"
    local backup_min="24"
    if [[ "$backup_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        backup_hour="${backup_time%:*}"
        backup_min="${backup_time#*:}"
    fi
    if [[ "$CRON_JOB_BACKUP" == true ]]; then
        printf "  ${CYAN}%s %s * * * %s %s -c \"%s/inmanage core backup\" >> /dev/null 2>&1${RESET}\n" \
            "$backup_min" "$backup_hour" "$user" "$INM_ENFORCED_SHELL" "$base_clean"
    fi
    if [[ "$CRON_JOB_HEARTBEAT" == true ]]; then
        local heartbeat_time="${INM_NOTIFY_HEARTBEAT_TIME:-06:00}"
        local heartbeat_hour="06"
        local heartbeat_min="00"
        if [[ "$heartbeat_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            heartbeat_hour="${heartbeat_time%:*}"
            heartbeat_min="${heartbeat_time#*:}"
        fi
        printf "  ${CYAN}%s %s * * * %s %s -c \"%s/inmanage core health --notify-heartbeat\" >> /dev/null 2>&1${RESET}\n" \
            "$heartbeat_min" "$heartbeat_hour" "$user" "$INM_ENFORCED_SHELL" "$base_clean"
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

    printf "\n${BLUE}%s${RESET}\n" "========================================"
    printf "${GREEN}${BOLD}Setup Complete!${RESET}\n\n"
    printf "${BOLD}Login:${RESET} ${CYAN}%s${RESET}\n" "$app_url"
    printf "${BOLD}Username:${RESET} admin@admin.com\n"
    printf "${BOLD}Password:${RESET} admin [change that ;-) *you're not goofy]\n"
    printf "${BLUE}%s${RESET}\n\n" "========================================"
    printf "${WHITE}Open your browser at ${CYAN}%s${RESET} to access the application.${RESET}\n" "$app_url"
    printf "The database and user are configured.\n\n"
    printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
    local installed_jobs="${INM_CRON_INSTALLED_JOBS:-$cron_jobs}"
    local cron_target="${INM_CRON_INSTALL_TARGET:-}"

    if [[ "$cron_skipped" == true ]]; then
        printf "${YELLOW}Cron install skipped (--no-cron-install).${RESET}\n\n"
    elif [[ "$cron_ok" == true ]]; then
        local summary
        summary="$(cron_jobs_summary "$installed_jobs")"
        printf "${GREEN}Cron installed (%s).${RESET}\n" "$summary"
        if [[ -n "$cron_target" ]]; then
            printf "${WHITE}Target:${RESET} %s\n\n" "$cron_target"
        else
            printf "\n"
        fi
    else
        print_cron_manual_instructions "$cron_jobs" "${INM_ENFORCED_USER:-$(whoami)}"
    fi
    printf "${MAGENTA}${BOLD}Your provision file must get removed manually once you are satisfied.${RESET}\n"
    printf "Delete ${CYAN}%s${RESET} since it has sensitive data stored.\n\n" "$provision_file"
}

print_wizard_summary() {
    local cron_ok="${1:-false}"
    local cron_jobs="${2:-artisan}"
    local cron_skipped="${3:-false}"
    local setup_url="https://your.url/setup"
    if [[ -n "${APP_URL:-}" ]]; then
        setup_url="${APP_URL%/}/setup"
    fi

    printf "\n${BLUE}%s${RESET}\n" "========================================"
    printf "${GREEN}${BOLD}Setup Complete!${RESET}\n\n"
    printf "${WHITE}Open your browser at your configured address ${CYAN}%s${RESET} to complete database setup.${RESET}\n\n" "$setup_url"
    printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
    local installed_jobs="${INM_CRON_INSTALLED_JOBS:-$cron_jobs}"
    local cron_target="${INM_CRON_INSTALL_TARGET:-}"

    if [[ "$cron_skipped" == true ]]; then
        printf "${YELLOW}Cron install skipped (--no-cron-install).${RESET}\n\n"
    elif [[ "$cron_ok" == true ]]; then
        local summary
        summary="$(cron_jobs_summary "$installed_jobs")"
        printf "${GREEN}Cron installed (%s).${RESET}\n" "$summary"
        if [[ -n "$cron_target" ]]; then
            printf "${WHITE}Target:${RESET} %s\n\n" "$cron_target"
        else
            printf "\n"
        fi
    else
        print_cron_manual_instructions "$cron_jobs" "${INM_ENFORCED_USER:-$(whoami)}"
    fi
}
