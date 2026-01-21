#!/usr/bin/env bash

# ---------------------------------------------------------------------
# print_provisioned_summary()
# Print the post-install summary for provisioned installs.
# Consumes: args: cron_ok, cron_jobs, cron_skipped; env: APP_URL, INM_PROVISION_FILE_USED, INM_PROVISION_ENV_FILE, INM_PATH_BASE_DIR.
# Computes: summary output and rollback/cron hints.
# Returns: 0 after printing.
# ---------------------------------------------------------------------
print_provisioned_summary() {
    local cron_ok="${1:-false}"
    local cron_jobs="${2:-essential}"
    local cron_skipped="${3:-false}"
    local app_url="${APP_URL:-https://your.url}"
    local provision_file="${INM_PROVISION_FILE_USED:-${INM_PROVISION_ENV_FILE:-.inmanage/.env.provision}}"
    if [[ "$provision_file" != /* ]]; then
        if [[ -n "${INM_PATH_BASE_DIR:-}" ]]; then
            provision_file="${INM_PATH_BASE_DIR%/}/${provision_file#/}"
        else
            provision_file="$(pwd)/${provision_file#/}"
        fi
    fi

    printf "\n%b%s%b\n" "$BLUE" "========================================" "$RESET"
    printf "%b%bSetup Complete!%b\n\n" "$GREEN" "$BOLD" "$RESET"
    local installed_version=""
    installed_version="$(get_installed_version 2>/dev/null || true)"
    if [ -n "$installed_version" ]; then
        printf "%bInvoice Ninja version:%b %s\n\n" "$BOLD" "$RESET" "$installed_version"
    fi
    printf "%bLogin:%b %b%s%b\n" "$BOLD" "$RESET" "$CYAN" "$app_url" "$RESET"
    printf "%bUsername:%b admin@admin.com\n" "$BOLD" "$RESET"
    printf "%bPassword:%b admin [change that ;-) *you're not goofy]\n" "$BOLD" "$RESET"
    printf "%b%s%b\n\n" "$BLUE" "========================================" "$RESET"
    printf "%bOpen your browser at %b%s%b to access the application.%b\n" "$WHITE" "$CYAN" "$app_url" "$RESET" "$RESET"
    printf "%bIt's a good time to make your first backup now!%b\n\n" "$YELLOW" "$RESET"
    local cli_cmd
    cli_cmd="$(install_cli_hint)"
    printf "Run: %b%s core backup%b\n\n" "$CYAN" "$cli_cmd" "$RESET"
    if [[ -n "${INM_INSTALL_ROLLBACK_DIR:-}" && -d "${INM_INSTALL_ROLLBACK_DIR:-/}" ]]; then
        local rollback_name rollback_cmd
        app_build_rollback_hint "install" "$INM_INSTALL_ROLLBACK_DIR" "$cli_cmd" rollback_name rollback_cmd
        if [[ -z "$rollback_name" ]]; then
            rollback_name="$(basename "$INM_INSTALL_ROLLBACK_DIR")"
        fi
        if [[ -z "$rollback_cmd" ]]; then
            rollback_cmd="${cli_cmd} core install rollback --latest (or: --name=${rollback_name})"
        fi
        printf "%bRollback available:%b %s\n" "$YELLOW" "$RESET" "$rollback_name"
        printf "Run: %b%s%b\n\n" "$CYAN" "$rollback_cmd" "$RESET"
    fi
    if [[ "$cron_skipped" == true ]]; then
        printf "%bCron install skipped (--no-cron-install).%b\n\n" "$YELLOW" "$RESET"
    else
        if [[ "$cron_ok" != true ]]; then
            print_cron_manual_instructions "$cron_jobs" "${INM_EXEC_USER:-$(whoami)}"
        fi
    fi
    printf "%b%bYour provision file must get removed manually once you are satisfied.%b\n" "$MAGENTA" "$BOLD" "$RESET"
    printf "Delete %b%s%b since it has sensitive data stored.\n\n" "$CYAN" "$provision_file" "$RESET"
}

# ---------------------------------------------------------------------
# print_wizard_summary()
# Print the post-install summary for wizard installs.
# Consumes: args: cron_ok, cron_jobs, cron_skipped; env: APP_URL.
# Computes: summary output and rollback/cron hints.
# Returns: 0 after printing.
# ---------------------------------------------------------------------
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
    local installed_version=""
    installed_version="$(get_installed_version 2>/dev/null || true)"
    if [ -n "$installed_version" ]; then
        printf "%bInvoice Ninja version:%b %s\n\n" "$BOLD" "$RESET" "$installed_version"
    fi
    printf "%bOpen your browser at your configured address %b%s%b to complete database setup.%b\n\n" "$WHITE" "$CYAN" "$setup_url" "$RESET" "$RESET"
    printf "%bIt's a good time to make your first backup now!%b\n\n" "$YELLOW" "$RESET"
    local cli_cmd
    cli_cmd="$(install_cli_hint)"
    printf "Run: %b%s core backup%b\n\n" "$CYAN" "$cli_cmd" "$RESET"
    if [[ -n "${INM_INSTALL_ROLLBACK_DIR:-}" && -d "${INM_INSTALL_ROLLBACK_DIR:-/}" ]]; then
        local rollback_name rollback_cmd
        app_build_rollback_hint "install" "$INM_INSTALL_ROLLBACK_DIR" "$cli_cmd" rollback_name rollback_cmd
        if [[ -z "$rollback_name" ]]; then
            rollback_name="$(basename "$INM_INSTALL_ROLLBACK_DIR")"
        fi
        if [[ -z "$rollback_cmd" ]]; then
            rollback_cmd="${cli_cmd} core install rollback --latest (or: --name=${rollback_name})"
        fi
        printf "%bRollback available:%b %s\n" "$YELLOW" "$RESET" "$rollback_name"
        printf "Run: %b%s%b\n\n" "$CYAN" "$rollback_cmd" "$RESET"
    fi
    if [[ "$cron_skipped" == true ]]; then
        printf "%bCron install skipped (--no-cron-install).%b\n\n" "$YELLOW" "$RESET"
    else
        if [[ "$cron_ok" != true ]]; then
            print_cron_manual_instructions "$cron_jobs" "${INM_EXEC_USER:-$(whoami)}"
        fi
    fi
}
