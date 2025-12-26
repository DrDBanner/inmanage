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
    local jobs="${args[jobs]:-${args[cron_jobs]:-${args[cron-jobs]:-both}}}"
    local cron_file="/etc/cron.d/invoiceninja"
    local cron_mode="${args[cron_mode]:-${args[cron-mode]:-${args[mode]:-auto}}}"
    cron_mode="${cron_mode,,}"
    export INM_CRON_INSTALLED_JOBS=""
    export INM_CRON_INSTALL_TARGET=""
    local backup_time="${args[backup_time]:-${args[backup-time]:-${INM_CRON_BACKUP_TIME:-03:24}}}"
    export INM_CRON_BACKUP_TIME="$backup_time"
    local backup_hour=""
    local backup_min=""
    if [[ "$backup_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        backup_hour="${backup_time%:*}"
        backup_min="${backup_time#*:}"
    else
        log warn "[CRON] Invalid --backup-time '$backup_time' (expected HH:MM); using 03:24."
        backup_time="03:24"
        INM_CRON_BACKUP_TIME="$backup_time"
        backup_hour="03"
        backup_min="24"
    fi
    local backup_cron_expr="${backup_min} ${backup_hour} * * *"

    if [[ -n "${args[cron_file]}" ]]; then
        cron_file="${args[cron_file]}"
    fi

    local use_user_crontab=false
    local can_sudo=false
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        can_sudo=true
    fi

    check_existing_cron_entries() {
        local found=false
        if command -v crontab >/dev/null 2>&1; then
            if crontab -l >/dev/null 2>&1; then
                if crontab -l | grep -Eqi 'inmanage|invoiceninja|artisan schedule:run'; then
                    log info "[CRON] Existing user crontab entries detected (Invoice Ninja/inmanage)."
                    found=true
                fi
            fi
        fi
        if [[ -f "$cron_file" ]]; then
            log info "[CRON] Existing cron file found at $cron_file (will be replaced)."
            found=true
        elif [[ "$can_sudo" == true ]]; then
            if sudo -n test -f "$cron_file" 2>/dev/null; then
                log info "[CRON] Existing cron file found at $cron_file (will be replaced)."
                found=true
            fi
        fi
        [[ "$found" == false ]] && log debug "[CRON] No existing Invoice Ninja cron entries detected."
    }

    case "$cron_mode" in
        ""|auto)
            if [[ $EUID -ne 0 ]]; then
                if [[ "$can_sudo" == true ]]; then
                    use_user_crontab=false
                else
                    log warn "[CRON] sudo requires a password or is not allowed; trying user crontab."
                    use_user_crontab=true
                fi
            fi
            ;;
        crontab)
            use_user_crontab=true
            ;;
        system)
            use_user_crontab=false
            if [[ $EUID -ne 0 && "$can_sudo" != true ]]; then
                log err "[CRON] System cron requested but sudo/root not available."
                return 1
            fi
            ;;
        *)
            log err "[CRON] Invalid --mode: $cron_mode (use auto|system|crontab)"
            return 1
            ;;
    esac

    check_existing_cron_entries

    local tmpfile
    tmpfile=$(mktemp)
    detect_installed_jobs() {
        local file="$1"
        local has_sched=false
        local has_backup=false
        if grep -qE 'schedule:run' "$file" 2>/dev/null; then
            has_sched=true
        fi
        if grep -qE 'inmanage core backup' "$file" 2>/dev/null; then
            has_backup=true
        fi
        if [[ "$has_sched" == true && "$has_backup" == true ]]; then
            printf "%s" "both"
        elif [[ "$has_sched" == true ]]; then
            printf "%s" "scheduler"
        elif [[ "$has_backup" == true ]]; then
            printf "%s" "backup"
        else
            printf "%s" ""
        fi
    }

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
                echo "${backup_cron_expr} $INM_ENFORCED_SHELL -c \"${base_clean}/inmanage core backup\" >> /dev/null 2>&1"
            fi
            echo "# INMANAGE CRON END"
        } >> "$tmpfile"

        if crontab "$tmpfile"; then
            INM_CRON_INSTALLED_JOBS="$(detect_installed_jobs "$tmpfile")"
            INM_CRON_INSTALL_TARGET="crontab"
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
            echo "${backup_cron_expr} $user $INM_ENFORCED_SHELL -c \"${base_clean}/inmanage core backup\" >> /dev/null 2>&1"
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
        INM_CRON_INSTALLED_JOBS="$(detect_installed_jobs "$tmpfile")"
        INM_CRON_INSTALL_TARGET="$cron_file"
        log ok "[CRON] Installed cronjobs in $cron_file"
    else
        log err "[CRON] Failed to write cron file."
        rm -f "$tmpfile"
        return 1
    fi

    rm -f "$tmpfile"
}

# ---------------------------------------------------------------------
# uninstall_cronjob()
# ---------------------------------------------------------------------
uninstall_cronjob() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cron uninstall."
        return 0
    fi
    declare -A args
    parse_named_args args "$@"

    local cron_file="/etc/cron.d/invoiceninja"
    local cron_mode="${args[cron_mode]:-${args[cron-mode]:-${args[mode]:-auto}}}"
    cron_mode="${cron_mode,,}"
    if [[ -n "${args[cron_file]}" ]]; then
        cron_file="${args[cron_file]}"
    fi

    local can_sudo=false
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        can_sudo=true
    fi

    local remove_user_crontab=false
    local remove_system=false
    case "$cron_mode" in
        ""|auto)
            remove_user_crontab=true
            remove_system=true
            ;;
        crontab)
            remove_user_crontab=true
            ;;
        system)
            remove_system=true
            ;;
        *)
            log err "[CRON] Invalid --mode: $cron_mode (use auto|system|crontab)"
            return 1
            ;;
    esac

    if [[ "$remove_user_crontab" == true ]]; then
        if ! command -v crontab >/dev/null 2>&1; then
            log warn "[CRON] crontab not available; skipping user crontab removal."
        else
            local tmpfile tmpclean
            tmpfile="$(mktemp)"
            tmpclean="${tmpfile}.clean"
            if crontab -l >/dev/null 2>&1; then
                crontab -l > "$tmpfile"
            else
                : > "$tmpfile"
            fi
            awk 'BEGIN{skip=0} /^# INMANAGE CRON BEGIN/{skip=1; next} /^# INMANAGE CRON END/{skip=0; next} !skip{print}' \
                "$tmpfile" > "$tmpclean"
            if cmp -s "$tmpfile" "$tmpclean"; then
                log info "[CRON] No INMANAGE block found in user crontab."
            else
                if crontab "$tmpclean"; then
                    log ok "[CRON] Removed INMANAGE block from user crontab."
                else
                    log err "[CRON] Failed to update user crontab."
                fi
            fi
            rm -f "$tmpfile" "$tmpclean"
        fi
    fi

    if [[ "$remove_system" == true ]]; then
        if [[ -f "$cron_file" ]]; then
            if [[ $EUID -ne 0 ]]; then
                if [[ "$can_sudo" != true ]]; then
                    log err "[CRON] Cannot remove $cron_file (need sudo/root)."
                else
                    sudo rm -f "$cron_file" && log ok "[CRON] Removed $cron_file"
                fi
            else
                rm -f "$cron_file" && log ok "[CRON] Removed $cron_file"
            fi
        elif [[ "$can_sudo" == true && $EUID -ne 0 ]]; then
            if sudo -n test -f "$cron_file" 2>/dev/null; then
                sudo rm -f "$cron_file" && log ok "[CRON] Removed $cron_file"
            else
                log info "[CRON] No cron file found at $cron_file."
            fi
        else
            log info "[CRON] No cron file found at $cron_file."
        fi
    fi
}
