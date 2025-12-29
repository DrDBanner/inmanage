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
    log info "[CRON] install_cronjob called (mode=${cron_mode:-auto} jobs=${jobs} backup-time=${backup_time} user=${user})"
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
    local cron_dir
    cron_dir="$(dirname "$cron_file")"
    local system_cron_available=false
    if [[ -d "$cron_dir" ]]; then
        if [[ $EUID -eq 0 ]]; then
            system_cron_available=true
        elif [[ "$can_sudo" == true ]]; then
            if sudo -n test -w "$cron_dir" 2>/dev/null; then
                system_cron_available=true
            fi
        fi
    fi

    check_existing_cron_entries() {
        local found=false
        local errexit_set=false
        [[ $- == *e* ]] && errexit_set=true
        set +e
        if command -v crontab >/dev/null 2>&1; then
            local crontab_out=""
            crontab_out="$(crontab -l 2>/dev/null || true)"
            if [[ -n "$crontab_out" ]]; then
                if printf "%s\n" "$crontab_out" | grep -Eqi 'inmanage|invoiceninja|artisan schedule:run'; then
                    log info "[CRON] Existing user crontab entries detected (Invoice Ninja/inmanage)."
                    found=true
                fi
            else
                log debug "[CRON] No user crontab entries found."
            fi
        else
            log debug "[CRON] crontab command not available."
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
        $errexit_set && set -e
    }

    local mode_reason="auto"
    case "$cron_mode" in
        ""|auto)
            if [[ "$system_cron_available" == true ]]; then
                use_user_crontab=false
                mode_reason="auto->system (cron.d writable)"
            else
                if command -v crontab >/dev/null 2>&1; then
                    use_user_crontab=true
                    mode_reason="auto->crontab (cron.d unavailable)"
                else
                    log err "[CRON] No usable system cron.d and crontab is missing; cannot install."
                    return 1
                fi
            fi
            ;;
        crontab)
            use_user_crontab=true
            mode_reason="crontab (forced)"
            ;;
        system)
            use_user_crontab=false
            mode_reason="system (forced)"
            if [[ "$system_cron_available" != true ]]; then
                log err "[CRON] System cron requested but ${cron_dir} is not writable or missing."
                return 1
            fi
            ;;
        *)
            log err "[CRON] Invalid --mode: $cron_mode (use auto|system|crontab)"
            return 1
            ;;
    esac

    check_existing_cron_entries
    if [[ "$use_user_crontab" == true ]]; then
        log info "[CRON] Mode resolved: crontab (${mode_reason})"
        log info "[CRON] Target: user crontab"
    else
        log info "[CRON] Mode resolved: system (${mode_reason})"
        log info "[CRON] Target: ${cron_file}"
    fi
    local job_summary=""
    if [[ "$jobs" == "scheduler" || "$jobs" == "both" ]]; then
        job_summary="scheduler"
    fi
    if [[ "$jobs" == "backup" || "$jobs" == "both" ]]; then
        job_summary="${job_summary:+${job_summary}, }backup@${backup_time}"
    fi
    log info "[CRON] Jobs selected: ${job_summary:-none}"
    if [[ "$jobs" == "scheduler" || "$jobs" == "both" ]]; then
        log info "[CRON] Will set: schedule:run every minute"
    fi
    if [[ "$jobs" == "backup" || "$jobs" == "both" ]]; then
        log info "[CRON] Will set: backup at ${backup_time}"
    fi

    local tmpfile
    if ! tmpfile=$(mktemp 2>/dev/null); then
        log err "[CRON] Failed to create temp file for crontab."
        return 1
    fi
    escape_squote() {
        printf "%s" "${1//\'/\'\\\'\'}"
    }
    resolve_cli_command() {
        local candidate
        local resolved=""
        local base_clean="${INM_BASE_DIRECTORY%/}"
        local candidates=()
        if [[ -n "${SCRIPT_PATH:-}" ]]; then
            candidates+=("$SCRIPT_PATH")
        fi
        if command -v inm >/dev/null 2>&1; then
            candidates+=("$(command -v inm)")
        fi
        if command -v inmanage >/dev/null 2>&1; then
            candidates+=("$(command -v inmanage)")
        fi
        if [[ -n "$base_clean" ]]; then
            candidates+=("${base_clean}/inmanage" "${base_clean}/inm")
        fi
        for candidate in "${candidates[@]}"; do
            [[ -z "$candidate" ]] && continue
            resolved="$(realpath "$candidate" 2>/dev/null || echo "$candidate")"
            if [ -x "$resolved" ]; then
                printf "%s" "$resolved"
                return 0
            fi
        done
        return 1
    }
    local cli_cmd=""
    cli_cmd="$(resolve_cli_command)" || {
        cli_cmd="inmanage"
        log warn "[CRON] Could not resolve CLI path; falling back to '${cli_cmd}' (PATH-dependent)."
    }
    local cli_cmd_escaped
    cli_cmd_escaped="$(escape_squote "$cli_cmd")"
    local base_clean="${INM_BASE_DIRECTORY%/}"
    local base_clean_escaped
    base_clean_escaped="$(escape_squote "$base_clean")"
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
            if ! crontab -l > "$tmpfile" 2>/dev/null; then
                log warn "[CRON] Failed to read existing user crontab; starting fresh."
                : > "$tmpfile"
            fi
        else
            : > "$tmpfile"
        fi
        if ! awk 'BEGIN{skip=0} /^# INMANAGE CRON BEGIN/{skip=1; next} /^# INMANAGE CRON END/{skip=0; next} !skip{print}' \
            "$tmpfile" > "$tmpclean"; then
            log err "[CRON] Failed to prepare user crontab."
            rm -f "$tmpfile" "$tmpclean"
            return 1
        fi
        if ! mv -f "$tmpclean" "$tmpfile"; then
            log err "[CRON] Failed to finalize user crontab."
            rm -f "$tmpfile" "$tmpclean"
            return 1
        fi

        {
            echo "# INMANAGE CRON BEGIN"
            if [[ "$jobs" == "scheduler" || "$jobs" == "both" ]]; then
                echo "* * * * * $(artisan_cmd_string) schedule:run >> /dev/null 2>&1"
            fi
            if [[ "$jobs" == "backup" || "$jobs" == "both" ]]; then
                echo "${backup_cron_expr} $INM_ENFORCED_SHELL -c 'cd ${base_clean_escaped} && ${cli_cmd_escaped} core backup' >> /dev/null 2>&1"
            fi
            echo "# INMANAGE CRON END"
        } >> "$tmpfile"

        if [[ "${DEBUG:-false}" == true ]]; then
            log debug "[CRON] New cron block:"
            sed -n '/^# INMANAGE CRON BEGIN/,/^# INMANAGE CRON END/p' "$tmpfile" >&2
        fi

        local crontab_out=""
        if crontab_out=$(crontab "$tmpfile" 2>&1); then
            INM_CRON_INSTALLED_JOBS="$(detect_installed_jobs "$tmpfile")"
            INM_CRON_INSTALL_TARGET="crontab"
            log ok "[CRON] Installed cronjobs in user crontab"
        else
            log err "[CRON] Failed to write user crontab${crontab_out:+: $crontab_out}"
            rm -f "$tmpfile"
            return 1
        fi
        rm -f "$tmpfile"
        return 0
    fi

    if ! {
        echo "# Invoice Ninja cronjobs"
        if [[ "$jobs" == "scheduler" || "$jobs" == "both" ]]; then
            echo "* * * * * $user $(artisan_cmd_string) schedule:run >> /dev/null 2>&1"
        fi
        if [[ "$jobs" == "backup" || "$jobs" == "both" ]]; then
            echo "${backup_cron_expr} $user $INM_ENFORCED_SHELL -c 'cd ${base_clean_escaped} && ${cli_cmd_escaped} core backup' >> /dev/null 2>&1"
        fi
    } > "$tmpfile"; then
        log err "[CRON] Failed to prepare cron file."
        rm -f "$tmpfile"
        return 1
    fi

    local tee_cmd=("tee" "$cron_file")
    if [[ $EUID -ne 0 ]]; then
        if [[ "$can_sudo" == true ]]; then
            tee_cmd=("sudo" "tee" "$cron_file")
        fi
    fi

    if cat "$tmpfile" | "${tee_cmd[@]}" >/dev/null; then
        if [[ $EUID -ne 0 ]]; then
            if ! sudo chmod 644 "$cron_file" >/dev/null 2>&1; then
                log err "[CRON] Failed to chmod $cron_file."
                rm -f "$tmpfile"
                return 1
            fi
        else
            if ! chmod 644 "$cron_file" >/dev/null 2>&1; then
                log err "[CRON] Failed to chmod $cron_file."
                rm -f "$tmpfile"
                return 1
            fi
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
    local cron_dir
    cron_dir="$(dirname "$cron_file")"
    local system_cron_possible=false
    if [[ -d "$cron_dir" ]]; then
        if [[ $EUID -eq 0 || "$can_sudo" == true ]]; then
            system_cron_possible=true
        fi
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
        if [[ "$system_cron_possible" != true ]]; then
            if [[ "$cron_mode" == "system" ]]; then
                log err "[CRON] System cron requested but ${cron_dir} is not available."
            else
                log debug "[CRON] System cron unavailable at ${cron_dir}; skipping system removal."
            fi
            return 0
        fi
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
            fi
        elif [[ -d "$cron_dir" ]]; then
            log info "[CRON] No cron file found at $cron_file."
        fi
    fi
}
