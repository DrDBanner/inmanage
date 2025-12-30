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

    local user
    user="$(args_get args "${INM_ENFORCED_USER:-}" user)"
    local jobs_raw
    jobs_raw="$(args_get args "both" jobs cron_jobs)"
    local create_test_job
    create_test_job="$(args_get args "false" create_test_job)"
    local cron_file="/etc/cron.d/invoiceninja"
    local remove_test_job
    remove_test_job="$(args_get args "false" remove_test_job)"
    local cron_mode
    cron_mode="$(args_get args "auto" cron_mode mode)"
    cron_mode="${cron_mode,,}"
    local jobs="${jobs_raw,,}"
    local create_test_job_enabled=false
    local remove_test_job_enabled=false
    args_is_true "$create_test_job" && create_test_job_enabled=true
    args_is_true "$remove_test_job" && remove_test_job_enabled=true
    local job_artisan=false
    local job_backup=false
    local job_heartbeat=false
    IFS=',' read -ra job_tokens <<<"$jobs"
    local token
    for token in "${job_tokens[@]}"; do
        token="${token,,}"
        case "$token" in
            scheduler|schedule|artisan|artisan:scheduler)
                job_artisan=true
                ;;
            backup)
                job_backup=true
                ;;
            heartbeat|notify|health|healthcheck)
                job_heartbeat=true
                ;;
            both|essential)
                job_artisan=true
                job_backup=true
                ;;
            all)
                job_artisan=true
                job_backup=true
                job_heartbeat=true
                ;;
            "")
                ;;
            *)
                log warn "[CRON] Unknown job: ${token}"
                ;;
        esac
    done
    if [[ "$job_artisan" != true && "$job_backup" != true && "$job_heartbeat" != true ]]; then
        job_artisan=true
        job_backup=true
    fi
    export INM_CRON_INSTALLED_JOBS=""
    export INM_CRON_INSTALL_TARGET=""
    local backup_time
    backup_time="$(args_get args "${INM_CRON_BACKUP_TIME:-03:24}" backup_time)"
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
    local heartbeat_time
    heartbeat_time="$(args_get args "${INM_NOTIFY_HEARTBEAT_TIME:-06:00}" heartbeat_time)"
    local heartbeat_hour=""
    local heartbeat_min=""
    if [[ "$heartbeat_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        heartbeat_hour="${heartbeat_time%:*}"
        heartbeat_min="${heartbeat_time#*:}"
    else
        log warn "[CRON] Invalid --heartbeat-time '$heartbeat_time' (expected HH:MM); using 06:00."
        heartbeat_time="06:00"
        heartbeat_hour="06"
        heartbeat_min="00"
    fi
    local heartbeat_cron_expr="${heartbeat_min} ${heartbeat_hour} * * *"

    local cron_file_arg=""
    cron_file_arg="$(args_get args "" cron_file)"
    if [[ -n "$cron_file_arg" ]]; then
        cron_file="$cron_file_arg"
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
        local home_cronfile="${HOME:-}/cronfile"
        if [[ -f "$home_cronfile" ]]; then
            if grep -Eqi 'inmanage|invoiceninja|artisan schedule:run' "$home_cronfile" 2>/dev/null; then
                log info "[CRON] Existing cronfile entries detected (${home_cronfile})."
                found=true
            fi
        fi
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
    local effective_user="$user"
    if [[ "$use_user_crontab" == true ]]; then
        effective_user="$(id -un 2>/dev/null || echo "$user")"
        if [[ -n "$user" && "$user" != "$effective_user" ]]; then
            log warn "[CRON] User crontab ignores --user; using current user '${effective_user}'."
        fi
    fi
    log info "[CRON] install_cronjob called (mode=${cron_mode:-auto} jobs=${jobs} backup-time=${backup_time} user=${effective_user})"
    if [[ "$use_user_crontab" == true ]]; then
        log info "[CRON] Mode resolved: crontab (${mode_reason})"
        log info "[CRON] Target: user crontab (user=${effective_user})"
    else
        log info "[CRON] Mode resolved: system (${mode_reason})"
        log info "[CRON] Target: ${cron_file} (user=${user})"
    fi
    local job_summary=""
    if [[ "$job_artisan" == true ]]; then
        job_summary="artisan"
    fi
    if [[ "$job_backup" == true ]]; then
        job_summary="${job_summary:+${job_summary}, }backup@${backup_time}"
    fi
    if [[ "$job_heartbeat" == true ]]; then
        job_summary="${job_summary:+${job_summary}, }heartbeat@${heartbeat_time}"
    fi
    if [[ "$create_test_job_enabled" == true ]]; then
        job_summary="${job_summary:+${job_summary}, }test"
    fi
    log info "[CRON] Jobs selected: ${job_summary:-none}"
    if [[ "$job_artisan" == true ]]; then
        log info "[CRON] Will set: schedule:run every minute"
    fi
    if [[ "$job_backup" == true ]]; then
        log info "[CRON] Will set: backup at ${backup_time}"
    fi
    if [[ "$job_heartbeat" == true ]]; then
        log info "[CRON] Will set: heartbeat check at ${heartbeat_time}"
    fi
    if [[ "$create_test_job_enabled" == true ]]; then
        log info "[CRON] Will set: cron test file every minute"
    fi

    local tmpfile
    if ! tmpfile=$(mktemp 2>/dev/null); then
        log err "[CRON] Failed to create temp file for crontab."
        return 1
    fi
    escape_squote() {
        printf "%s" "${1//\'/\'\\\'\'}"
    }
    local cli_cmd=""
    if declare -F resolve_cli_command_path >/dev/null 2>&1; then
        cli_cmd="$(resolve_cli_command_path)" || cli_cmd=""
    fi
    if [[ -z "$cli_cmd" ]]; then
        cli_cmd="inmanage"
        log warn "[CRON] Could not resolve CLI path; falling back to '${cli_cmd}' (PATH-dependent)."
    fi
    local cli_cmd_escaped
    cli_cmd_escaped="$(escape_squote "$cli_cmd")"
    local base_clean="${INM_BASE_DIRECTORY%/}"
    if [[ -z "$base_clean" ]]; then
        base_clean="$(pwd)"
    fi
    local base_clean_escaped
    base_clean_escaped="$(escape_squote "$base_clean")"
    local touch_cmd=""
    if command -v touch >/dev/null 2>&1; then
        touch_cmd="$(command -v touch)"
    else
        touch_cmd="touch"
    fi
    local touch_cmd_escaped
    touch_cmd_escaped="$(escape_squote "$touch_cmd")"
    detect_installed_jobs() {
        local file="$1"
        local -a jobs=()
        if grep -qE 'schedule:run' "$file" 2>/dev/null; then
            jobs+=("artisan")
        fi
        if grep -qE 'inmanage(\.sh)? core backup|inm core backup' "$file" 2>/dev/null; then
            jobs+=("backup")
        fi
        if grep -qE 'notify-heartbeat' "$file" 2>/dev/null; then
            jobs+=("heartbeat")
        fi
        if [[ ${#jobs[@]} -gt 0 ]]; then
            local IFS=,
            printf "%s" "${jobs[*]}"
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
        local home_cronfile="${HOME:-}/cronfile"
        local use_home_cronfile=false
        if [[ -f "$home_cronfile" ]]; then
            if cp "$home_cronfile" "$tmpfile" 2>/dev/null; then
                use_home_cronfile=true
                log info "[CRON] Using existing cronfile: $home_cronfile"
            else
                log warn "[CRON] Failed to read ${home_cronfile}; falling back to user crontab."
            fi
        fi
        if [[ "$use_home_cronfile" != true ]]; then
            if crontab -l >/dev/null 2>&1; then
                if ! crontab -l > "$tmpfile" 2>/dev/null; then
                    log warn "[CRON] Failed to read existing user crontab; starting fresh."
                    : > "$tmpfile"
                fi
            else
                : > "$tmpfile"
            fi
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
            if [[ "$job_artisan" == true ]]; then
                echo "* * * * * $(artisan_cmd_string) schedule:run >> /dev/null 2>&1"
            fi
            if [[ "$job_backup" == true ]]; then
                echo "${backup_cron_expr} $INM_ENFORCED_SHELL -c 'cd ${base_clean_escaped} && ${cli_cmd_escaped} core backup' >> /dev/null 2>&1"
            fi
            if [[ "$job_heartbeat" == true ]]; then
                echo "${heartbeat_cron_expr} $INM_ENFORCED_SHELL -c 'cd ${base_clean_escaped} && ${cli_cmd_escaped} core health --notify-heartbeat' >> /dev/null 2>&1"
            fi
            if [[ "$create_test_job_enabled" == true ]]; then
                echo "# INMANAGE CRON TEST"
                echo "* * * * * $INM_ENFORCED_SHELL -c 'cd ${base_clean_escaped} && ${touch_cmd_escaped} crontestfile' >> /dev/null 2>&1"
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
            if [[ "$use_home_cronfile" == true ]]; then
                cp "$tmpfile" "$home_cronfile" 2>/dev/null || \
                    log warn "[CRON] Failed to update ${home_cronfile} after install."
            fi
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
        if [[ "$job_artisan" == true ]]; then
            echo "* * * * * $user $(artisan_cmd_string) schedule:run >> /dev/null 2>&1"
        fi
        if [[ "$job_backup" == true ]]; then
            echo "${backup_cron_expr} $user $INM_ENFORCED_SHELL -c 'cd ${base_clean_escaped} && ${cli_cmd_escaped} core backup' >> /dev/null 2>&1"
        fi
        if [[ "$job_heartbeat" == true ]]; then
            echo "${heartbeat_cron_expr} $user $INM_ENFORCED_SHELL -c 'cd ${base_clean_escaped} && ${cli_cmd_escaped} core health --notify-heartbeat' >> /dev/null 2>&1"
        fi
        if [[ "$create_test_job_enabled" == true ]]; then
            echo "# INMANAGE CRON TEST"
            echo "* * * * * $user $INM_ENFORCED_SHELL -c 'cd ${base_clean_escaped} && ${touch_cmd_escaped} crontestfile' >> /dev/null 2>&1"
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
    local cron_mode
    cron_mode="$(args_get args "auto" cron_mode mode)"
    cron_mode="${cron_mode,,}"
    local cron_file_arg=""
    cron_file_arg="$(args_get args "" cron_file)"
    if [[ -n "$cron_file_arg" ]]; then
        cron_file="$cron_file_arg"
    fi
    local remove_test_job
    remove_test_job="$(args_get args "false" remove_test_job)"
    local remove_test_job_enabled=false
    args_is_true "$remove_test_job" && remove_test_job_enabled=true

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

    if [[ "$remove_test_job_enabled" == true ]]; then
        log info "[CRON] Removing cron test job only."
        remove_test_lines() {
            awk '!/crontestfile/ && !/INMANAGE CRON TEST/' "$1" > "$2"
        }
        local removed=false
        if [[ "$remove_user_crontab" == true ]]; then
            if ! command -v crontab >/dev/null 2>&1; then
                log warn "[CRON] crontab not available; skipping test job removal."
            else
                local tmpfile tmpclean
                tmpfile="$(mktemp)"
                tmpclean="${tmpfile}.clean"
                if crontab -l >/dev/null 2>&1; then
                    crontab -l > "$tmpfile"
                else
                    : > "$tmpfile"
                fi
                remove_test_lines "$tmpfile" "$tmpclean"
                if cmp -s "$tmpfile" "$tmpclean"; then
                    log info "[CRON] No cron test job found in user crontab."
                else
                    if crontab "$tmpclean"; then
                        log ok "[CRON] Removed cron test job from user crontab."
                        removed=true
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
                    log debug "[CRON] System cron unavailable at ${cron_dir}; skipping test job removal."
                fi
            else
                local tmpfile tmpclean
                tmpfile="$(mktemp)"
                tmpclean="${tmpfile}.clean"
                if [[ -f "$cron_file" ]]; then
                    cat "$cron_file" > "$tmpfile"
                elif [[ "$can_sudo" == true && $EUID -ne 0 ]]; then
                    if sudo -n test -f "$cron_file" 2>/dev/null; then
                        sudo cat "$cron_file" | tee "$tmpfile" >/dev/null
                    else
                        : > "$tmpfile"
                    fi
                else
                    : > "$tmpfile"
                fi
                remove_test_lines "$tmpfile" "$tmpclean"
                if cmp -s "$tmpfile" "$tmpclean"; then
                    log info "[CRON] No cron test job found in ${cron_file}."
                else
                    local tee_cmd=("tee" "$cron_file")
                    if [[ $EUID -ne 0 && "$can_sudo" == true ]]; then
                        tee_cmd=("sudo" "tee" "$cron_file")
                    fi
                    if cat "$tmpclean" | "${tee_cmd[@]}" >/dev/null; then
                        log ok "[CRON] Removed cron test job from ${cron_file}."
                        removed=true
                    else
                        log err "[CRON] Failed to update ${cron_file}."
                    fi
                fi
                rm -f "$tmpfile" "$tmpclean"
            fi
        fi
        [[ "$removed" == false ]] && log info "[CRON] No cron test job removed."
        return 0
    fi

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
