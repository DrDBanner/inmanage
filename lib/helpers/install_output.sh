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
    local jobs="${1:-scheduler}"
    local user="${2:-$INM_ENFORCED_USER}"
    local cli_cmd
    cli_cmd="$(install_cli_hint)"
    local base_clean="${INM_BASE_DIRECTORY%/}"

    printf "${MAGENTA}Cron install failed.${RESET}\n"
    printf "Try: ${CYAN}%s core cron install --user=%s --jobs=%s${RESET}\n" "$cli_cmd" "$user" "$jobs"
    printf "Or add to ${CYAN}/etc/cron.d/invoiceninja${RESET} (root):\n"
    if [[ "$jobs" == "scheduler" || "$jobs" == "both" ]]; then
        printf "  ${CYAN}* * * * * %s %s schedule:run >> /dev/null 2>&1${RESET}\n" "$user" "$(artisan_cmd_string)"
    fi
    if [[ "$jobs" == "backup" || "$jobs" == "both" ]]; then
        printf "  ${CYAN}0 3 * * * %s %s -c \"%s/inmanage core backup\" >> /dev/null 2>&1${RESET}\n" \
            "$user" "$INM_ENFORCED_SHELL" "$base_clean"
    fi
    printf "\n"
}

print_provisioned_summary() {
    local cron_ok="${1:-false}"
    local cron_jobs="${2:-both}"
    local app_url="${APP_URL:-https://your.url}"

    printf "\n${BLUE}%s${RESET}\n" "========================================"
    printf "${GREEN}${BOLD}Setup Complete!${RESET}\n\n"
    printf "${BOLD}Login:${RESET} ${CYAN}%s${RESET}\n" "$app_url"
    printf "${BOLD}Username:${RESET} admin@admin.com\n"
    printf "${BOLD}Password:${RESET} admin\n"
    printf "${BLUE}%s${RESET}\n\n" "========================================"
    printf "${WHITE}Open your browser at ${CYAN}%s${RESET} to access the application.${RESET}\n" "$app_url"
    printf "The database and user are configured.\n\n"
    printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
    if [[ "$cron_ok" == true ]]; then
        if [[ "$cron_jobs" == "both" ]]; then
            printf "${GREEN}Cron installed (scheduler + backup).${RESET}\n\n"
        else
            printf "${GREEN}Cron installed (scheduler).${RESET}\n\n"
        fi
    else
        print_cron_manual_instructions "$cron_jobs" "${INM_ENFORCED_USER:-$(whoami)}"
    fi
}

print_wizard_summary() {
    local cron_ok="${1:-false}"
    local cron_jobs="${2:-scheduler}"
    local setup_url="https://your.url/setup"
    if [[ -n "${APP_URL:-}" ]]; then
        setup_url="${APP_URL%/}/setup"
    fi

    printf "\n${BLUE}%s${RESET}\n" "========================================"
    printf "${GREEN}${BOLD}Setup Complete!${RESET}\n\n"
    printf "${WHITE}Open your browser at your configured address ${CYAN}%s${RESET} to complete database setup.${RESET}\n\n" "$setup_url"
    printf "${YELLOW}It's a good time to make your first backup now!${RESET}\n\n"
    if [[ "$cron_ok" == true ]]; then
        printf "${GREEN}Cron installed (scheduler).${RESET}\n\n"
    else
        print_cron_manual_instructions "$cron_jobs" "${INM_ENFORCED_USER:-$(whoami)}"
    fi
}
