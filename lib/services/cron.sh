#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_CRON_LOADED:-} ]] && return
__SERVICE_CRON_LOADED=1

# ---------------------------------------------------------------------
# install_cronjob()
# ---------------------------------------------------------------------
install_cronjob() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cron installation."
        return 0
    fi
    declare -A args
    parse_named_args args "$@"

    local user="${args[user]:-$INM_ENFORCED_USER}"
    local jobs="${args[jobs]:-scheduler}"
    local cron_file="/etc/cron.d/invoiceninja"

    if [[ -n "${args[cron_file]}" ]]; then
        cron_file="${args[cron_file]}"
    fi

    if [[ $EUID -ne 0 ]]; then
        log warn "[CRON] Not running as root. Trying sudo..."
        if ! command -v sudo >/dev/null; then
            log err "[CRON] sudo not available; cannot install cronjob system-wide."
            return 1
        fi
    fi

    local tmpfile
    tmpfile=$(mktemp)

    {
        echo "# Invoice Ninja cronjobs"
        if [[ "$jobs" == "scheduler" || "$jobs" == "both" ]]; then
            echo "* * * * * $user $(artisan_cmd_string) schedule:run >> /dev/null 2>&1"
        fi
        if [[ "$jobs" == "backup" || "$jobs" == "both" ]]; then
            local base_clean="${INM_BASE_DIRECTORY%/}"
            echo "0 3 * * * $user $INM_ENFORCED_SHELL -c \"${base_clean}/inmanage core backup\" >> /dev/null 2>&1"
        fi
    } > "$tmpfile"

    if cat "$tmpfile" | sudo tee "$cron_file" >/dev/null; then
        sudo chmod 644 "$cron_file"
        log ok "[CRON] Installed cronjobs in $cron_file"
    else
        log err "[CRON] Failed to write cron file."
        rm -f "$tmpfile"
        return 1
    fi

    rm -f "$tmpfile"
}
