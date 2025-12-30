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

print_cron_manual_instructions() {
    local jobs="${1:-artisan}"
    local user="${2:-$INM_ENFORCED_USER}"
    local cli_cmd
    cli_cmd="$(install_cli_hint)"
    local base_clean="${INM_BASE_DIRECTORY%/}"

    printf "${MAGENTA}Cron install failed.${RESET}\n"
    case "${jobs,,}" in
        scheduler|schedule|artisan|artisan:scheduler) jobs="artisan" ;;
    esac
    printf "Try: ${CYAN}%s core cron install --user=%s --jobs=%s${RESET}\n" "$cli_cmd" "$user" "$jobs"
    printf "Or add to ${CYAN}/etc/cron.d/invoiceninja${RESET} (root):\n"
    if [[ "$jobs" == "artisan" || "$jobs" == "both" ]]; then
        printf "  ${CYAN}* * * * * %s %s schedule:run >> /dev/null 2>&1${RESET}\n" "$user" "$(artisan_cmd_string)"
    fi
    local backup_time="${INM_CRON_BACKUP_TIME:-03:24}"
    local backup_hour="03"
    local backup_min="24"
    if [[ "$backup_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        backup_hour="${backup_time%:*}"
        backup_min="${backup_time#*:}"
    fi
    if [[ "$jobs" == "backup" || "$jobs" == "both" ]]; then
        printf "  ${CYAN}%s %s * * * %s %s -c \"%s/inmanage core backup\" >> /dev/null 2>&1${RESET}\n" \
            "$backup_min" "$backup_hour" "$user" "$INM_ENFORCED_SHELL" "$base_clean"
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
    case "${installed_jobs,,}" in
        scheduler|schedule|artisan|artisan:scheduler) installed_jobs="artisan" ;;
    esac
    local cron_target="${INM_CRON_INSTALL_TARGET:-}"

    if [[ "$cron_skipped" == true ]]; then
        printf "${YELLOW}Cron install skipped (--no-cron-install).${RESET}\n\n"
    elif [[ "$cron_ok" == true ]]; then
        case "$installed_jobs" in
            both) printf "${GREEN}Cron installed (artisan + backup).${RESET}\n" ;;
            artisan) printf "${GREEN}Cron installed (artisan).${RESET}\n" ;;
            backup) printf "${GREEN}Cron installed (backup).${RESET}\n" ;;
            *) printf "${GREEN}Cron installed.${RESET}\n" ;;
        esac
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
    case "${installed_jobs,,}" in
        scheduler|schedule|artisan|artisan:scheduler) installed_jobs="artisan" ;;
    esac
    local cron_target="${INM_CRON_INSTALL_TARGET:-}"

    if [[ "$cron_skipped" == true ]]; then
        printf "${YELLOW}Cron install skipped (--no-cron-install).${RESET}\n\n"
    elif [[ "$cron_ok" == true ]]; then
        case "$installed_jobs" in
            both) printf "${GREEN}Cron installed (artisan + backup).${RESET}\n" ;;
            artisan) printf "${GREEN}Cron installed (artisan).${RESET}\n" ;;
            backup) printf "${GREEN}Cron installed (backup).${RESET}\n" ;;
            *) printf "${GREEN}Cron installed.${RESET}\n" ;;
        esac
        if [[ -n "$cron_target" ]]; then
            printf "${WHITE}Target:${RESET} %s\n\n" "$cron_target"
        else
            printf "\n"
        fi
    else
        print_cron_manual_instructions "$cron_jobs" "${INM_ENFORCED_USER:-$(whoami)}"
    fi
}
