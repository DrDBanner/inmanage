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

    local use_user_crontab=false
    local can_sudo=false
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null; then
            if sudo -n true >/dev/null 2>&1; then
                can_sudo=true
            else
                log warn "[CRON] sudo requires a password or is not allowed; trying user crontab."
                use_user_crontab=true
            fi
        else
            log warn "[CRON] sudo not available; trying user crontab."
            use_user_crontab=true
        fi
    fi

    local tmpfile
    tmpfile=$(mktemp)

    if [[ "$use_user_crontab" == true ]]; then
        if ! command -v crontab >/dev/null 2>&1; then
            log err "[CRON] crontab not available; cannot install cronjob for user."
            rm -f "$tmpfile"
            return 1
        fi

        local tmpclean="${tmpfile}.clean"
        if crontab -l >/dev/null 2>&1; then
            crontab -l > "$tmpfile"
        else
            : > "$tmpfile"
        fi
        awk 'BEGIN{skip=0} /^# INMANAGE CRON BEGIN/{skip=1; next} /^# INMANAGE CRON END/{skip=0; next} !skip{print}' \
            "$tmpfile" > "$tmpclean"
        mv -f "$tmpclean" "$tmpfile"

        {
            echo "# INMANAGE CRON BEGIN"
            if [[ "$jobs" == "scheduler" || "$jobs" == "both" ]]; then
                echo "* * * * * $(artisan_cmd_string) schedule:run >> /dev/null 2>&1"
            fi
            if [[ "$jobs" == "backup" || "$jobs" == "both" ]]; then
                local base_clean="${INM_BASE_DIRECTORY%/}"
                echo "0 3 * * * $INM_ENFORCED_SHELL -c \"${base_clean}/inmanage core backup\" >> /dev/null 2>&1"
            fi
            echo "# INMANAGE CRON END"
        } >> "$tmpfile"

        if crontab "$tmpfile"; then
            log ok "[CRON] Installed cronjobs in user crontab"
        else
            log err "[CRON] Failed to write user crontab."
            rm -f "$tmpfile"
            return 1
        fi
        rm -f "$tmpfile"
        return 0
    fi

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

    local tee_cmd=("tee" "$cron_file")
    if [[ $EUID -ne 0 ]]; then
        if [[ "$can_sudo" == true ]]; then
            tee_cmd=("sudo" "tee" "$cron_file")
        fi
    fi

    if cat "$tmpfile" | "${tee_cmd[@]}" >/dev/null; then
        if [[ $EUID -ne 0 ]]; then
            sudo chmod 644 "$cron_file"
        else
            chmod 644 "$cron_file"
        fi
        log ok "[CRON] Installed cronjobs in $cron_file"
    else
        log err "[CRON] Failed to write cron file."
        rm -f "$tmpfile"
        return 1
    fi

    rm -f "$tmpfile"
}
