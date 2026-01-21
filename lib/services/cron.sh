#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_CRON_LOADED:-} ]] && return
__SERVICE_CRON_LOADED=1

cron_strip_instance_block() {
    local infile="$1"
    local outfile="$2"
    local id="$3"
    awk -v id="$id" '
        BEGIN {skip=0}
        $0 ~ "^# INMANAGE INSTANCE "id" BEGIN" {skip=1; next}
        $0 ~ "^# INMANAGE INSTANCE "id" END" {skip=0; next}
        $0 ~ "^# INMANAGE CRON BEGIN" {skip=1; next}
        $0 ~ "^# INMANAGE CRON END" {skip=0; next}
        !skip {print}
    ' "$infile" > "$outfile"
}

cron_strip_instance_block_by_base() {
    local infile="$1"
    local outfile="$2"
    local base="$3"
    if [[ -z "$base" ]]; then
        cat "$infile" > "$outfile"
        return 0
    fi
    awk -v base="$base" '
        BEGIN {in_block=0; keep=1; n=0}
        function flush_block() {
            for (i = 1; i <= n; i++) print buf[i]
            n = 0
        }
        /^# INMANAGE INSTANCE / && / BEGIN$/ {
            in_block=1; keep=1; n=0
        }
        {
            if (in_block) {
                n++; buf[n]=$0
                if ($0 == "# INMANAGE INSTANCE BASE=" base) keep=0
                if ($0 ~ /^# INMANAGE INSTANCE / && $0 ~ / END$/) {
                    if (keep == 1) flush_block()
                    in_block=0
                }
                next
            }
            print
        }
    ' "$infile" > "$outfile"
}

cron_escape_awk_re() {
    local re="$1"
    re="${re//\\/\\\\}"
    printf "%s" "$re"
}

cron_is_interactive() {
    [[ -t 0 && -t 1 ]]
}

cron_heartbeat_requirements_ok() {
    local notify_enabled="${INM_NOTIFY_ENABLE:-false}"
    local heartbeat_enabled="${INM_NOTIFY_HEARTBEAT_ENABLE:-false}"
    if ! args_is_true "$notify_enabled"; then
        return 1
    fi
    if ! args_is_true "$heartbeat_enabled"; then
        return 1
    fi
    local targets="${INM_NOTIFY_TARGETS_LIST:-}"
    targets="${targets,,}"
    targets="${targets//[[:space:]]/}"
    if [[ -z "$targets" ]]; then
        return 1
    fi
    local has_email=false
    local has_webhook=false
    local part
    IFS=',' read -ra parts <<<"$targets"
    for part in "${parts[@]}"; do
        case "$part" in
            email) has_email=true ;;
            webhook) has_webhook=true ;;
        esac
    done
    if [[ "$has_email" == true && -z "${INM_NOTIFY_EMAIL_TO_LIST:-}" ]]; then
        return 1
    fi
    if [[ "$has_webhook" == true && -z "${INM_NOTIFY_WEBHOOK_URL:-}" ]]; then
        return 1
    fi
    return 0
}

cron_prompt_heartbeat_config() {
    if ! cron_is_interactive; then
        return 1
    fi
    if ! declare -F prompt_confirm >/dev/null 2>&1; then
        return 1
    fi
    if ! declare -F prompt_var >/dev/null 2>&1; then
        return 1
    fi
    if ! declare -F env_set >/dev/null 2>&1; then
        return 1
    fi
    if ! prompt_confirm "CRON_HB_SETUP" "yes" \
        "[CRON] Heartbeat notifications are not configured. Configure now? (yes/no):" false 120; then
        return 1
    fi

    local notify_enabled="${INM_NOTIFY_ENABLE:-false}"
    if ! args_is_true "$notify_enabled"; then
        if prompt_confirm "CRON_NOTIFY_ENABLE" "yes" \
            "[CRON] Enable notifications (INM_NOTIFY_ENABLE)? (yes/no):" false 60; then
            env_set cli "INM_NOTIFY_ENABLE=true" >/dev/null 2>&1 || true
        else
            env_set cli "INM_NOTIFY_ENABLE=false" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    local heartbeat_enabled="${INM_NOTIFY_HEARTBEAT_ENABLE:-true}"
    if ! args_is_true "$heartbeat_enabled"; then
        if prompt_confirm "CRON_HB_ENABLE" "yes" \
            "[CRON] Enable heartbeat notifications (INM_NOTIFY_HEARTBEAT_ENABLE)? (yes/no):" false 60; then
            env_set cli "INM_NOTIFY_HEARTBEAT_ENABLE=true" >/dev/null 2>&1 || true
        else
            env_set cli "INM_NOTIFY_HEARTBEAT_ENABLE=false" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    local targets="${INM_NOTIFY_TARGETS_LIST:-}"
    if [[ -z "$targets" ]]; then
        targets="$(prompt_var "CRON_NOTIFY_TARGETS" "email" \
            "[CRON] Notification targets (comma-separated: email,webhook):" false 120)" || return 1
        targets="${targets,,}"
        targets="${targets//[[:space:]]/}"
        env_set cli "INM_NOTIFY_TARGETS_LIST=${targets}" >/dev/null 2>&1 || true
    fi

    targets="${targets,,}"
    targets="${targets//[[:space:]]/}"
    local need_email=false
    local need_webhook=false
    local part
    IFS=',' read -ra parts <<<"$targets"
    for part in "${parts[@]}"; do
        case "$part" in
            email) need_email=true ;;
            webhook) need_webhook=true ;;
        esac
    done

    if [[ "$need_email" == true && -z "${INM_NOTIFY_EMAIL_TO_LIST:-}" ]]; then
        local email_to=""
        email_to="$(prompt_var "CRON_NOTIFY_EMAIL_TO" "" \
            "[CRON] Email recipients (comma-separated, blank disables email):" false 120)" || return 1
        if [[ -n "$email_to" ]]; then
            env_set cli "INM_NOTIFY_EMAIL_TO_LIST=${email_to}" >/dev/null 2>&1 || true
        else
            need_email=false
        fi
    fi

    if [[ "$need_webhook" == true && -z "${INM_NOTIFY_WEBHOOK_URL:-}" ]]; then
        local webhook_url=""
        webhook_url="$(prompt_var "CRON_NOTIFY_WEBHOOK_URL" "" \
            "[CRON] Webhook URL (blank disables webhook):" false 120)" || return 1
        if [[ -n "$webhook_url" ]]; then
            env_set cli "INM_NOTIFY_WEBHOOK_URL=${webhook_url}" >/dev/null 2>&1 || true
        else
            need_webhook=false
        fi
    fi

    local targets_new=()
    if [[ "$need_email" == true ]]; then
        targets_new+=("email")
    fi
    if [[ "$need_webhook" == true ]]; then
        targets_new+=("webhook")
    fi
    if (( ${#targets_new[@]} == 0 )); then
        env_set cli "INM_NOTIFY_TARGETS_LIST=" >/dev/null 2>&1 || true
        return 1
    fi
    local new_targets_str=""
    if (( ${#targets_new[@]} > 0 )); then
        local IFS=,
        new_targets_str="${targets_new[*]}"
    fi
    if [[ "$new_targets_str" != "$targets" ]]; then
        env_set cli "INM_NOTIFY_TARGETS_LIST=${new_targets_str}" >/dev/null 2>&1 || true
        targets="$new_targets_str"
    fi

    if [[ -n "${INM_SELF_ENV_FILE:-}" && -f "${INM_SELF_ENV_FILE}" ]] && declare -F load_env_file_raw >/dev/null 2>&1; then
        load_env_file_raw "$INM_SELF_ENV_FILE" || true
    fi

    cron_heartbeat_requirements_ok
    return $?
}

cron_strip_legacy_lines() {
    local infile="$1"
    local outfile="$2"
    local base="${3%/}"
    local env="${4%/}"
    local base_re=""
    local env_re=""
    if [[ -n "$base" ]]; then
        base_re="$(escape_regex "$base")"
    fi
    if [[ -n "$env" ]]; then
        env_re="$(escape_regex "$env")"
    fi
    local base_re_awk=""
    local env_re_awk=""
    base_re_awk="$(cron_escape_awk_re "$base_re")"
    env_re_awk="$(cron_escape_awk_re "$env_re")"
    awk -v base_re="$base_re_awk" -v env_re="$env_re_awk" '
        BEGIN {
            have_base=(base_re != "")
            have_env=(env_re != "")
        }
        /^# Invoice Ninja cronjobs/ {next}
        {
            line=$0
            match_scope=0
            if (have_base && line ~ base_re) match_scope=1
            if (have_env && line ~ env_re) match_scope=1
            if (line ~ /INM_SELF_INSTANCE_ID=|INM_INSTANCE_ID=/) {print; next}
            if (match_scope && line ~ /(inmanage(\.sh)?|inm(\.sh)?|notify-heartbeat|artisan[[:space:]]+schedule:run|core[[:space:]]+backup)/) next
            print
        }
    ' "$infile" > "$outfile"
}

cron_strip_instance_only() {
    local infile="$1"
    local outfile="$2"
    local id="$3"
    local id_re=""
    id_re="$(cron_escape_awk_re "$(escape_regex "$id")")"
    awk -v id_re="$id_re" '
        BEGIN {skip=0}
        $0 ~ "^# INMANAGE INSTANCE "id_re" BEGIN" {skip=1; next}
        $0 ~ "^# INMANAGE INSTANCE "id_re" END" {skip=0; next}
        skip {next}
        $0 ~ "INM_SELF_INSTANCE_ID="id_re {next}
        $0 ~ "INM_INSTANCE_ID="id_re {next}
        {print}
    ' "$infile" > "$outfile"
}

cron_strip_all_inmanage() {
    local infile="$1"
    local outfile="$2"
    awk '
        BEGIN {skip=0}
        /^# INMANAGE INSTANCE / && $0 ~ / BEGIN$/ {skip=1; next}
        /^# INMANAGE INSTANCE / && $0 ~ / END$/ {skip=0; next}
        /^# INMANAGE CRON BEGIN/ {skip=1; next}
        /^# INMANAGE CRON END/ {skip=0; next}
        skip {next}
        /^# Invoice Ninja cronjobs/ {next}
        /INM_SELF_INSTANCE_ID=|INM_INSTANCE_ID=/ {next}
        /(inmanage(\.sh)?|inm(\.sh)?|notify-heartbeat|artisan[[:space:]]+schedule:run|core[[:space:]]+backup)/ {next}
        {print}
    ' "$infile" > "$outfile"
}

cron_read_crontab() {
    local user="${1:-}"
    if ! command -v crontab >/dev/null 2>&1; then
        return 1
    fi
    local current_user
    current_user="$(id -un 2>/dev/null || true)"
    if [[ -z "$user" || "$user" == "$current_user" ]]; then
        crontab -l 2>/dev/null || true
        return 0
    fi
    crontab -l -u "$user" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------
# install_cronjob()
# Install cron jobs for scheduler/backup/heartbeat.
# Consumes: args: user/jobs/mode/backup_time/heartbeat_time; env: INM_EXEC_USER.
# Computes: cron.d or user crontab entries.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
install_cronjob() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cron installation."
        return 0
    fi
    # shellcheck disable=SC2034
    # shellcheck disable=SC2034
    # shellcheck disable=SC2034
    declare -A args
    local -a normalized_args=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" == --* ]]; then
            normalized_args+=("$arg")
        elif [[ "$arg" == *=* ]]; then
            normalized_args+=("--$arg")
        else
            normalized_args+=("$arg")
        fi
    done
    parse_named_args args "${normalized_args[@]}"

    local user
    user="$(args_get args "${INM_EXEC_USER:-}" user)"
    local jobs_raw
    jobs_raw="$(args_get args "essential" jobs cron_jobs)"
    local cron_mode
    cron_mode="$(args_get args "auto" cron_mode mode)"
    cron_mode="${cron_mode,,}"
    local base_clean="${INM_PATH_BASE_DIR%/}"
    if [[ -z "$base_clean" ]]; then
        base_clean="$(pwd)"
    fi
    local env_clean="${INM_PATH_APP_ENV_FILE%/}"
    local instance_id
    instance_id="$(env_resolve_instance_id "$base_clean" "$env_clean")"
    local cron_file_default="/etc/cron.d/inmanage-${instance_id}"
    local cron_file="$cron_file_default"
    local jobs="${jobs_raw,,}"
    local job_artisan=false
    local job_backup=false
    local job_heartbeat=false
    local job_test=false
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
            test)
                job_test=true
                ;;
            "")
                ;;
            *)
                log warn "[CRON] Unknown job: ${token}"
                ;;
        esac
    done
    if [[ "$job_artisan" != true && "$job_backup" != true && "$job_heartbeat" != true && "$job_test" != true ]]; then
        job_artisan=true
        job_backup=true
    fi

    if [[ "$job_heartbeat" == true ]]; then
        if ! cron_heartbeat_requirements_ok; then
            if cron_prompt_heartbeat_config; then
                :
            else
                log warn "[CRON] Heartbeat job skipped; notification settings incomplete."
                job_heartbeat=false
            fi
        fi
    fi
    if [[ "$job_artisan" != true && "$job_backup" != true && "$job_heartbeat" != true && "$job_test" != true ]]; then
        job_artisan=true
        job_backup=true
        log warn "[CRON] No valid jobs selected; falling back to essential jobs."
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
            log info "[CRON] Existing cron file found at $cron_file (will be updated)."
            found=true
        elif [[ "$can_sudo" == true ]]; then
            if sudo -n test -f "$cron_file" 2>/dev/null; then
                log info "[CRON] Existing cron file found at $cron_file (will be updated)."
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

    local merge_existing_jobs=true
    if [[ "$merge_existing_jobs" == true ]]; then
        local existing_artisan=false
        local existing_backup=false
        local existing_heartbeat=false
        local existing_test=false
        cron_collect_existing_jobs() {
            local data="$1"
            local in_block=false
            local line
            while IFS= read -r line; do
                if [[ "$line" == "# INMANAGE INSTANCE ${instance_id} BEGIN" ]]; then
                    in_block=true
                    continue
                fi
                if [[ "$line" == "# INMANAGE INSTANCE ${instance_id} END" ]]; then
                    in_block=false
                    continue
                fi
                if [[ "$in_block" != true ]]; then
                    continue
                fi
                if echo "$line" | grep -Eq "schedule:run"; then
                    existing_artisan=true
                fi
                if echo "$line" | grep -Eq "core[[:space:]]+backup"; then
                    existing_backup=true
                fi
                if echo "$line" | grep -Eq "notify-heartbeat"; then
                    existing_heartbeat=true
                fi
                if echo "$line" | grep -Eq "INMANAGE CRON TEST|crontestfile\\."; then
                    existing_test=true
                fi
            done <<< "$data"
        }
        local existing_data=""
        if [[ "$use_user_crontab" == true ]]; then
            if command -v crontab >/dev/null 2>&1; then
                existing_data="$(cron_read_crontab "")"
            fi
        else
            if [[ -f "$cron_file" ]]; then
                existing_data="$(cat "$cron_file" 2>/dev/null || true)"
            elif [[ "$can_sudo" == true && $EUID -ne 0 ]]; then
                if sudo -n test -f "$cron_file" 2>/dev/null; then
                    existing_data="$(sudo cat "$cron_file" 2>/dev/null || true)"
                fi
            fi
        fi
        if [[ -n "$existing_data" ]]; then
            cron_collect_existing_jobs "$existing_data"
            if [[ "$existing_artisan" == true || "$existing_backup" == true || "$existing_heartbeat" == true || "$existing_test" == true ]]; then
                [[ "$existing_artisan" == true ]] && job_artisan=true
                [[ "$existing_backup" == true ]] && job_backup=true
                [[ "$existing_heartbeat" == true ]] && job_heartbeat=true
                if [[ "$existing_test" == true ]]; then
                    job_test=true
                fi
                local existing_summary=()
                [[ "$existing_artisan" == true ]] && existing_summary+=("artisan")
                [[ "$existing_backup" == true ]] && existing_summary+=("backup")
                [[ "$existing_heartbeat" == true ]] && existing_summary+=("heartbeat")
                [[ "$existing_test" == true ]] && existing_summary+=("test")
                log debug "[CRON] Merging requested jobs with existing instance jobs: ${existing_summary[*]}"
            fi
        fi
    fi
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
    if [[ "$job_test" == true ]]; then
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
    if [[ "$job_test" == true ]]; then
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
    cli_cmd="$(resolve_cli_command_path)" || cli_cmd=""
    if [[ -z "$cli_cmd" ]]; then
        cli_cmd="inmanage"
        log warn "[CRON] Could not resolve CLI path; falling back to '${cli_cmd}' (PATH-dependent)."
    fi
    local cli_cmd_escaped
    cli_cmd_escaped="$(escape_squote "$cli_cmd")"
    local instance_block_begin="# INMANAGE INSTANCE ${instance_id} BEGIN"
    local instance_block_end="# INMANAGE INSTANCE ${instance_id} END"
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
    local -a installed_jobs=()
    if [[ "$job_artisan" == true ]]; then
        installed_jobs+=("artisan")
    fi
    if [[ "$job_backup" == true ]]; then
        installed_jobs+=("backup")
    fi
    if [[ "$job_heartbeat" == true ]]; then
        installed_jobs+=("heartbeat")
    fi
    if [[ "$job_test" == true ]]; then
        installed_jobs+=("test")
    fi
    local installed_jobs_str=""
    if (( ${#installed_jobs[@]} > 0 )); then
        local IFS=,
        installed_jobs_str="${installed_jobs[*]}"
    fi
    render_instance_block() {
        local include_user="$1"
        local cron_user="$2"
        local user_prefix=""
        if [[ "$include_user" == true && -n "$cron_user" ]]; then
            user_prefix="${cron_user} "
        fi
        echo "${instance_block_begin}"
        echo "# INMANAGE INSTANCE BASE=${base_clean}"
        if [[ "$job_artisan" == true ]]; then
            echo "* * * * * ${user_prefix}$(artisan_cmd_string) schedule:run >> /dev/null 2>&1"
        fi
        if [[ "$job_backup" == true ]]; then
            echo "${backup_cron_expr} ${user_prefix}$INM_EXEC_SHELL_BIN -c 'cd ${base_clean_escaped} && ${cli_cmd_escaped} core backup' >> /dev/null 2>&1"
        fi
        if [[ "$job_heartbeat" == true ]]; then
            echo "${heartbeat_cron_expr} ${user_prefix}$INM_EXEC_SHELL_BIN -c 'cd ${base_clean_escaped} && ${cli_cmd_escaped} core health --notify-heartbeat' >> /dev/null 2>&1"
        fi
        if [[ "$job_test" == true ]]; then
            local test_file="crontestfile.${instance_id}"
            local test_file_escaped
            test_file_escaped="$(escape_squote "$test_file")"
            echo "# INMANAGE CRON TEST ${instance_id}"
            echo "* * * * * ${user_prefix}$INM_EXEC_SHELL_BIN -c 'cd ${base_clean_escaped} && ${touch_cmd_escaped} ${test_file_escaped}' >> /dev/null 2>&1"
        fi
        echo "${instance_block_end}"
    }
    local cron_block_crontab
    cron_block_crontab="$(render_instance_block false "")"
    local cron_block_system
    cron_block_system="$(render_instance_block true "$user")"

    if [[ "$use_user_crontab" == true ]]; then
        if ! command -v crontab >/dev/null 2>&1; then
            log err "[CRON] crontab not available; cannot install cronjob for user."
            rm -f "$tmpfile"
            return 1
        fi

        local tmpclean="${tmpfile}.clean"
        local home_cronfile="${HOME:-}/cronfile"
        local use_home_cronfile=false
        local home_cronfile_writable=false
        if [[ -f "$home_cronfile" && -w "$home_cronfile" ]]; then
            home_cronfile_writable=true
        fi
        local crontab_has_entries=false
        local crontab_out=""
        crontab_out="$(cron_read_crontab "")"
        if [[ -n "$crontab_out" ]]; then
            printf "%s\n" "$crontab_out" > "$tmpfile"
            crontab_has_entries=true
        else
            : > "$tmpfile"
        fi
        if [[ "$crontab_has_entries" != true && -f "$home_cronfile" ]]; then
            if cp "$home_cronfile" "$tmpfile" 2>/dev/null; then
                use_home_cronfile=true
                log info "[CRON] Using existing cronfile: $home_cronfile"
            else
                log warn "[CRON] Failed to read ${home_cronfile}; continuing with user crontab."
            fi
        elif [[ -f "$home_cronfile" && "$crontab_has_entries" == true ]]; then
            log debug "[CRON] User crontab has entries; ignoring existing cronfile: $home_cronfile"
        fi
        if ! cron_strip_instance_block "$tmpfile" "$tmpclean" "$instance_id"; then
            log err "[CRON] Failed to prepare user crontab."
            rm -f "$tmpfile" "$tmpclean"
            return 1
        fi
        if ! mv -f "$tmpclean" "$tmpfile"; then
            log err "[CRON] Failed to finalize user crontab."
            rm -f "$tmpfile" "$tmpclean"
            return 1
        fi

        if [[ -s "$tmpfile" ]]; then
            printf "\n" >> "$tmpfile"
        fi
        printf "%s\n" "$cron_block_crontab" >> "$tmpfile"

        if [[ "${DEBUG:-false}" == true ]]; then
            log debug "[CRON] New cron block:"
            sed -n "/^# INMANAGE INSTANCE ${instance_id} BEGIN/,/^# INMANAGE INSTANCE ${instance_id} END/p" "$tmpfile" >&2
        fi

        local crontab_out=""
        if crontab_out=$(crontab "$tmpfile" 2>&1); then
            INM_CRON_INSTALLED_JOBS="$installed_jobs_str"
            INM_CRON_INSTALL_TARGET="crontab"
            log ok "[CRON] Installed cronjobs in user crontab"
            if [[ "$use_home_cronfile" == true ]]; then
                if [[ "$home_cronfile_writable" == true ]]; then
                    cp "$tmpfile" "$home_cronfile" 2>/dev/null || \
                        log warn "[CRON] Failed to update ${home_cronfile} after install."
                else
                    log debug "[CRON] Cronfile not writable; skipping sync: ${home_cronfile}"
                fi
            fi
        else
            log err "[CRON] Failed to write user crontab${crontab_out:+: $crontab_out}"
            rm -f "$tmpfile"
            return 1
        fi
        rm -f "$tmpfile"
        return 0
    fi

    local tmpclean="${tmpfile}.clean"
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
    if ! cron_strip_instance_block "$tmpfile" "$tmpclean" "$instance_id"; then
        log err "[CRON] Failed to update cron file."
        rm -f "$tmpfile" "$tmpclean"
        return 1
    fi
    if ! mv -f "$tmpclean" "$tmpfile"; then
        log err "[CRON] Failed to prepare cron file."
        rm -f "$tmpfile" "$tmpclean"
        return 1
    fi
    if [[ -s "$tmpfile" ]]; then
        printf "\n" >> "$tmpfile"
    fi
    printf "%s\n" "$cron_block_system" >> "$tmpfile"

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
        INM_CRON_INSTALLED_JOBS="$installed_jobs_str"
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
# ---------------------------------------------------------------------
# uninstall_cronjob()
# Remove INmanage cron jobs.
# Consumes: args: user/mode; env: INM_EXEC_USER.
# Computes: cron file removal or crontab cleanup.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
uninstall_cronjob() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cron uninstall."
        return 0
    fi
    # shellcheck disable=SC2034
    declare -A args
    local -a normalized_args=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" == --* ]]; then
            normalized_args+=("$arg")
        elif [[ "$arg" == *=* ]]; then
            normalized_args+=("--$arg")
        else
            normalized_args+=("$arg")
        fi
    done
    parse_named_args args "${normalized_args[@]}"

    local cron_mode
    cron_mode="$(args_get args "auto" cron_mode mode)"
    cron_mode="${cron_mode,,}"
    local jobs_raw
    jobs_raw="$(args_get args "" jobs cron_jobs)"
    local jobs_specified=false
    if [[ -n "${args[jobs]:-}" || -n "${args[cron_jobs]:-}" ]]; then
        jobs_specified=true
    fi
    local jobs="${jobs_raw,,}"
    local instance_id_override=""
    instance_id_override="$(args_get args "" instance_id instance uuid)"
    local base_clean="${INM_PATH_BASE_DIR%/}"
    if [[ -z "$base_clean" ]]; then
        base_clean="$(pwd)"
    fi
    local env_clean="${INM_PATH_APP_ENV_FILE%/}"
    local instance_id
    instance_id="$(env_resolve_instance_id "$base_clean" "$env_clean")"
    if [[ -n "$instance_id_override" ]]; then
        instance_id="$instance_id_override"
    fi
    local cron_file_default="/etc/cron.d/inmanage-${instance_id}"
    local cron_file="$cron_file_default"
    local cron_file_arg=""
    cron_file_arg="$(args_get args "" cron_file)"
    if [[ -n "$cron_file_arg" ]]; then
        cron_file="$cron_file_arg"
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
    local remove_legacy=true
    if [[ -n "$instance_id_override" ]]; then
        remove_legacy=false
    fi

    local remove_job_artisan=false
    local remove_job_backup=false
    local remove_job_heartbeat=false
    local remove_job_test=false
    if [[ "$jobs_specified" == true ]]; then
        local job_tokens=()
        IFS=',' read -ra job_tokens <<<"$jobs"
        local token
        for token in "${job_tokens[@]}"; do
            token="${token,,}"
            case "$token" in
                scheduler|schedule|artisan|artisan:scheduler)
                    remove_job_artisan=true
                    ;;
                backup)
                    remove_job_backup=true
                    ;;
                heartbeat|notify|health|healthcheck)
                    remove_job_heartbeat=true
                    ;;
                test)
                    remove_job_test=true
                    ;;
                essential|both)
                    remove_job_artisan=true
                    remove_job_backup=true
                    ;;
                all)
                    remove_job_artisan=true
                    remove_job_backup=true
                    remove_job_heartbeat=true
                    remove_job_test=true
                    ;;
                "")
                    ;;
                *)
                    log warn "[CRON] Unknown job: ${token}"
                    ;;
            esac
        done
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

    if [[ "$jobs_specified" == true ]]; then
        local remove_re_parts=()
        [[ "$remove_job_artisan" == true ]] && remove_re_parts+=("schedule:run")
        [[ "$remove_job_backup" == true ]] && remove_re_parts+=("core[[:space:]]+backup")
        [[ "$remove_job_heartbeat" == true ]] && remove_re_parts+=("notify-heartbeat")
        [[ "$remove_job_test" == true ]] && remove_re_parts+=("INMANAGE CRON TEST" "crontestfile\\.")
        if (( ${#remove_re_parts[@]} == 0 )); then
            log info "[CRON] No jobs selected for removal."
            return 0
        fi
        local remove_re
        remove_re="$(printf "%s|" "${remove_re_parts[@]}")"
        remove_re="${remove_re%|}"
        local any_removed=false
        cron_strip_instance_jobs() {
            local in_file="$1"
            local out_file="$2"
            awk -v id="$instance_id" -v re="$remove_re" '
                BEGIN { in_block=0 }
                $0 ~ "^# INMANAGE INSTANCE " id " BEGIN" { in_block=1; print; next }
                $0 ~ "^# INMANAGE INSTANCE " id " END" { in_block=0; print; next }
                {
                    if (in_block && $0 ~ re) next
                    print
                }
            ' "$in_file" > "$out_file"
        }
        cron_instance_has_jobs() {
            awk -v id="$instance_id" '
                BEGIN { in_block=0; found=0 }
                $0 ~ "^# INMANAGE INSTANCE " id " BEGIN" { in_block=1; next }
                $0 ~ "^# INMANAGE INSTANCE " id " END" { in_block=0; next }
                in_block && $0 ~ /(schedule:run|core[[:space:]]+backup|notify-heartbeat|INMANAGE CRON TEST|crontestfile\.)/ { found=1 }
                END { exit(found ? 0 : 1) }
            ' "$1"
        }
        if [[ "$remove_user_crontab" == true ]]; then
            if ! command -v crontab >/dev/null 2>&1; then
                log warn "[CRON] crontab not available; skipping job removal."
            else
                local tmpfile tmpclean tmpfinal
                tmpfile="$(mktemp)"
                tmpclean="${tmpfile}.clean"
                tmpfinal="${tmpfile}.final"
                local crontab_out=""
                crontab_out="$(cron_read_crontab "")"
                if [[ -n "$crontab_out" ]]; then
                    printf "%s\n" "$crontab_out" > "$tmpfile"
                else
                    : > "$tmpfile"
                fi
                cron_strip_instance_jobs "$tmpfile" "$tmpclean"
                if cmp -s "$tmpfile" "$tmpclean"; then
                    log info "[CRON] No matching jobs found in user crontab."
                else
                    if ! cron_instance_has_jobs "$tmpclean"; then
                        cron_strip_instance_block "$tmpclean" "$tmpfinal" "$instance_id" || true
                    else
                        mv -f "$tmpclean" "$tmpfinal"
                    fi
                    if crontab "$tmpfinal"; then
                        log ok "[CRON] Removed selected jobs from user crontab."
                        any_removed=true
                    else
                        log err "[CRON] Failed to update user crontab."
                    fi
                fi
                rm -f "$tmpfile" "$tmpclean" "$tmpfinal"
            fi
        fi
        if [[ "$remove_system" == true ]]; then
            if [[ "$system_cron_possible" != true ]]; then
                if [[ "$cron_mode" == "system" ]]; then
                    log err "[CRON] System cron requested but ${cron_dir} is not available."
                else
                    log debug "[CRON] System cron unavailable at ${cron_dir}; skipping job removal."
                fi
            else
                local tmpfile tmpclean tmpfinal
                tmpfile="$(mktemp)"
                tmpclean="${tmpfile}.clean"
                tmpfinal="${tmpfile}.final"
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
                cron_strip_instance_jobs "$tmpfile" "$tmpclean"
                if cmp -s "$tmpfile" "$tmpclean"; then
                    log info "[CRON] No matching jobs found in ${cron_file}."
                else
                    if ! cron_instance_has_jobs "$tmpclean"; then
                        cron_strip_instance_block "$tmpclean" "$tmpfinal" "$instance_id" || true
                    else
                        mv -f "$tmpclean" "$tmpfinal"
                    fi
                    local tee_cmd=("tee" "$cron_file")
                    if [[ $EUID -ne 0 && "$can_sudo" == true ]]; then
                        tee_cmd=("sudo" "tee" "$cron_file")
                    fi
                    if cat "$tmpfinal" | "${tee_cmd[@]}" >/dev/null; then
                        log ok "[CRON] Removed selected jobs from ${cron_file}."
                        any_removed=true
                    else
                        log err "[CRON] Failed to update ${cron_file}."
                    fi
                fi
                rm -f "$tmpfile" "$tmpclean" "$tmpfinal"
            fi
        fi
        [[ "$any_removed" != true ]] && log info "[CRON] No cron jobs removed."
        return 0
    fi

    if [[ "$remove_user_crontab" == true ]]; then
        if ! command -v crontab >/dev/null 2>&1; then
            log warn "[CRON] crontab not available; skipping user crontab removal."
        else
            local tmpfile tmpclean tmporig
            tmpfile="$(mktemp)"
            tmpclean="${tmpfile}.clean"
            tmporig="${tmpfile}.orig"
            local crontab_out=""
            crontab_out="$(cron_read_crontab "")"
            if [[ -n "$crontab_out" ]]; then
                printf "%s\n" "$crontab_out" > "$tmpfile"
            else
                : > "$tmpfile"
            fi
            cp "$tmpfile" "$tmporig" 2>/dev/null || true
            if [[ -n "$instance_id_override" ]]; then
                cron_strip_instance_only "$tmpfile" "$tmpclean" "$instance_id"
                mv -f "$tmpclean" "$tmpfile"
            else
                cron_strip_instance_block "$tmpfile" "$tmpclean" "$instance_id"
                if [[ "$remove_legacy" == true ]]; then
                    cron_strip_legacy_lines "$tmpclean" "$tmpfile" "$INM_PATH_BASE_DIR" "$INM_PATH_APP_ENV_FILE"
                else
                    mv -f "$tmpclean" "$tmpfile"
                fi
            fi
            if cmp -s "$tmporig" "$tmpfile"; then
                if [[ -n "$instance_id_override" ]]; then
                    log warn "[CRON] No matching instance id found in user crontab (id=${instance_id_override})."
                else
                    local has_inmanage=false
                    if grep -Eq 'INM_SELF_INSTANCE_ID=|INM_INSTANCE_ID=|inmanage|notify-heartbeat|artisan[[:space:]]+schedule:run|core[[:space:]]+backup' "$tmporig" 2>/dev/null; then
                        has_inmanage=true
                    fi
                    if [[ "$has_inmanage" == true ]]; then
                        log warn "[CRON] User crontab has INmanage entries for another instance; use --instance-id to remove."
                    else
                        log info "[CRON] No INMANAGE block found in user crontab."
                    fi
                fi
            else
                if crontab "$tmpfile"; then
                    log ok "[CRON] Removed INMANAGE block from user crontab."
                else
                    log err "[CRON] Failed to update user crontab."
                fi
            fi
            rm -f "$tmpfile" "$tmpclean" "$tmporig"
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
        local tmpfile tmpclean tmporig
        tmpfile="$(mktemp)"
        tmpclean="${tmpfile}.clean"
        tmporig="${tmpfile}.orig"
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
        cp "$tmpfile" "$tmporig" 2>/dev/null || true
        if [[ -n "$instance_id_override" ]]; then
            cron_strip_instance_only "$tmpfile" "$tmpclean" "$instance_id"
            mv -f "$tmpclean" "$tmpfile"
        else
            cron_strip_instance_block "$tmpfile" "$tmpclean" "$instance_id"
            if [[ "$remove_legacy" == true ]]; then
                cron_strip_legacy_lines "$tmpclean" "$tmpfile" "$base_clean" "$env_clean"
            else
                mv -f "$tmpclean" "$tmpfile"
            fi
        fi
        if cmp -s "$tmporig" "$tmpfile"; then
            if [[ -n "$instance_id_override" ]]; then
                log warn "[CRON] No matching instance id found in ${cron_file} (id=${instance_id_override})."
            else
                local has_inmanage=false
                if grep -Eq 'INM_SELF_INSTANCE_ID=|INM_INSTANCE_ID=|inmanage|notify-heartbeat|artisan[[:space:]]+schedule:run|core[[:space:]]+backup' "$tmporig" 2>/dev/null; then
                    has_inmanage=true
                fi
                if [[ "$has_inmanage" == true ]]; then
                    log warn "[CRON] ${cron_file} has INmanage entries for another instance; use --instance-id to remove."
                else
                    log info "[CRON] No INMANAGE block found in ${cron_file}."
                fi
            fi
        else
            local has_content=false
            if grep -Eq '^[[:space:]]*[^#[:space:]]' "$tmpfile"; then
                has_content=true
            fi
            if [[ "$has_content" == true ]]; then
                local tee_cmd=("tee" "$cron_file")
                if [[ $EUID -ne 0 && "$can_sudo" == true ]]; then
                    tee_cmd=("sudo" "tee" "$cron_file")
                fi
                if cat "$tmpfile" | "${tee_cmd[@]}" >/dev/null; then
                    log ok "[CRON] Removed INMANAGE block from ${cron_file}."
                else
                    log err "[CRON] Failed to update ${cron_file}."
                fi
            else
                if [[ $EUID -ne 0 ]]; then
                    if [[ "$can_sudo" != true ]]; then
                        log err "[CRON] Cannot remove $cron_file (need sudo/root)."
                    else
                        sudo rm -f "$cron_file" && log ok "[CRON] Removed $cron_file"
                    fi
                else
                    rm -f "$cron_file" && log ok "[CRON] Removed $cron_file"
                fi
            fi
        fi
        rm -f "$tmpfile" "$tmpclean" "$tmporig"
    fi
}

# ---------------------------------------------------------------------
# cron_emit_preflight()
# Emit cron/scheduler status for preflight output.
# Consumes: args: add_fn, enforced_user, current_user, invoked_user; env: INM_PATH_BASE_DIR/INM_INSTALLATION_PATH/INM_NOTIFY_*.
# Computes: cron presence and job status lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
cron_emit_preflight() {
    local add_fn="$1"
    local enforced_user="${2:-${INM_EXEC_USER:-}}"
    local current_user="${3:-$(id -un 2>/dev/null || true)}"
    local invoked_user="${4:-${INM_INVOKED_BY:-$current_user}}"
    if [[ -z "${INM_SELF_INSTANCE_ID:-}" ]]; then
        env_resolve_instance_id "${INM_PATH_BASE_DIR:-}" "${INM_PATH_APP_ENV_FILE:-}" >/dev/null 2>&1 || true
    fi
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    cron_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "CRON" "$detail"
        else
            case "$status" in
                OK) log info "[CRON] $detail" ;;
                WARN) log warn "[CRON] $detail" ;;
                ERR) log err "[CRON] $detail" ;;
                INFO) log info "[CRON] $detail" ;;
                *) log info "[CRON] $detail" ;;
            esac
        fi
    }

    local cron_running=false
    if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || pgrep -x systemd >/dev/null 2>&1; then
        cron_running=true
    elif [[ -f /var/run/cron.pid || -f /var/run/crond.pid ]]; then
        cron_running=true
    elif command -v service >/dev/null 2>&1; then
        if service -e 2>/dev/null | grep -Eq '/cron$'; then
            cron_running=true
        fi
    fi
    if [[ "$cron_running" == true ]]; then
        cron_emit OK "Scheduler service present"
    else
        cron_emit WARN "No cron service detected"
    fi

    local can_read_enforced=false
    local can_read_invoked=false
    local invoked_snapshot_used=false
    if [[ -n "$enforced_user" && "$enforced_user" != "$current_user" ]]; then
        if [[ $EUID -eq 0 ]]; then
            can_read_enforced=true
        elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
            can_read_enforced=true
        fi
    fi
    if [[ -n "$invoked_user" && "$invoked_user" != "$current_user" ]]; then
        if [[ $EUID -eq 0 ]]; then
            can_read_invoked=true
        elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
            can_read_invoked=true
        fi
    fi

    local cron_dir="/etc/cron.d"
    local invoked_snapshot_file="${INM_INVOKED_CRON_SNAPSHOT:-}"
    local -a cron_entry_source=()
    local -a cron_entry_user=()
    local -a cron_entry_line=()
    local -a cron_sources=()

    cron_format_source() {
        local src="$1"
        case "$src" in
            crontab:*) printf "crontab(%s)" "${src#crontab:}" ;;
            cron.d:*) printf "cron.d(%s)" "${src#cron.d:}" ;;
            cronfile:*) printf "cronfile(%s)" "${src#cronfile:}" ;;
            snapshot:*) printf "snapshot(%s)" "${src#snapshot:}" ;;
            *) printf "%s" "$src" ;;
        esac
    }

    cron_add_source() {
        local src
        src="$(cron_format_source "$1")"
        local existing
        for existing in "${cron_sources[@]}"; do
            [[ "$existing" == "$src" ]] && return 0
        done
        cron_sources+=("$src")
    }

    cron_add_entry() {
        cron_entry_source+=("$(cron_format_source "$1")")
        cron_entry_user+=("$2")
        cron_entry_line+=("$3")
    }

    cron_is_schedule_line() {
        local line="$1"
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && return 1
        [[ "$trimmed" == @* ]] && return 0
        local f1 f2 f3 f4 f5
        read -r f1 f2 f3 f4 f5 _ <<< "$trimmed"
        [[ -n "$f5" ]] || return 1
        return 0
    }

    cron_add_lines() {
        local source="$1"
        local run_as="$2"
        local content="$3"
        local line trimmed entry_user
        while IFS= read -r line; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
            cron_is_schedule_line "$trimmed" || continue
            entry_user="$run_as"
            if [[ -z "$entry_user" && "$source" == cron.d:* ]]; then
                if [[ "$trimmed" == @* ]]; then
                    entry_user="$(awk '{print $2}' <<< "$trimmed")"
                else
                    entry_user="$(awk '{print $6}' <<< "$trimmed")"
                fi
            fi
            [[ -z "$entry_user" ]] && entry_user="unknown"
            cron_add_entry "$source" "$entry_user" "$trimmed"
        done <<< "$content"
    }

    if command -v crontab >/dev/null 2>&1; then
        local current_cron=""
        current_cron="$(cron_read_crontab "$current_user")"
        if [[ -n "$current_cron" ]]; then
            cron_add_source "crontab:${current_user}"
            cron_add_lines "crontab:${current_user}" "$current_user" "$current_cron"
        fi
        if [[ -n "$enforced_user" && "$enforced_user" != "$current_user" && "$can_read_enforced" == true ]]; then
            local enforced_cron=""
            if [[ $EUID -eq 0 ]]; then
                enforced_cron="$(cron_read_crontab "$enforced_user")"
            elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
                enforced_cron="$(sudo -n crontab -l -u "$enforced_user" 2>/dev/null || true)"
            fi
            cron_add_source "crontab:${enforced_user}"
            cron_add_lines "crontab:${enforced_user}" "$enforced_user" "$enforced_cron"
        fi
        if [[ -n "$invoked_user" && "$invoked_user" != "$current_user" && "$can_read_invoked" == true ]]; then
            local invoked_cron=""
            if [[ $EUID -eq 0 ]]; then
                invoked_cron="$(cron_read_crontab "$invoked_user")"
            elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
                invoked_cron="$(sudo -n crontab -l -u "$invoked_user" 2>/dev/null || true)"
            fi
            cron_add_source "crontab:${invoked_user}"
            cron_add_lines "crontab:${invoked_user}" "$invoked_user" "$invoked_cron"
        fi
    fi
    if [[ -n "$invoked_snapshot_file" && -r "$invoked_snapshot_file" ]]; then
        cron_add_source "snapshot:${invoked_user}"
        cron_add_lines "snapshot:${invoked_user}" "$invoked_user" "$(cat "$invoked_snapshot_file" 2>/dev/null || true)"
        invoked_snapshot_used=true
        rm -f "$invoked_snapshot_file" 2>/dev/null || true
    fi
    local -a cron_d_files=()
    if [[ -d "$cron_dir" ]]; then
        local nullglob_was_set=0
        shopt -q nullglob && nullglob_was_set=1
        shopt -s nullglob
        cron_d_files+=("$cron_dir"/inmanage-*)
        if [[ -r "${cron_dir}/invoiceninja" ]]; then
            cron_d_files+=("${cron_dir}/invoiceninja")
        fi
        if [[ "$nullglob_was_set" -eq 0 ]]; then
            shopt -u nullglob
        fi
    fi
    local cron_d_file
    for cron_d_file in "${cron_d_files[@]}"; do
        if [[ -r "$cron_d_file" ]]; then
            local cron_label
            cron_label="$(basename "$cron_d_file")"
            cron_add_source "cron.d:${cron_label}"
            cron_add_lines "cron.d:${cron_label}" "" "$(cat "$cron_d_file" 2>/dev/null || true)"
        fi
    done
    local home_cronfile="${HOME:-}/cronfile"
    if [[ -r "$home_cronfile" ]]; then
        cron_add_source "cronfile:${current_user}"
        cron_add_lines "cronfile:${current_user}" "$current_user" "$(cat "$home_cronfile" 2>/dev/null || true)"
    fi
    if [[ -n "$enforced_user" && "$enforced_user" != "$current_user" ]]; then
        local enforced_home=""
        if command -v getent >/dev/null 2>&1; then
            enforced_home="$(getent passwd "$enforced_user" 2>/dev/null | cut -d: -f6)"
        fi
        if [[ -z "$enforced_home" ]]; then
            enforced_home="$(eval echo "~$enforced_user" 2>/dev/null || true)"
        fi
        if [[ -n "$enforced_home" && "$enforced_home" != "~$enforced_user" ]]; then
            local enforced_cronfile="${enforced_home%/}/cronfile"
            if [[ -r "$enforced_cronfile" ]]; then
                cron_add_source "cronfile:${enforced_user}"
                cron_add_lines "cronfile:${enforced_user}" "$enforced_user" "$(cat "$enforced_cronfile" 2>/dev/null || true)"
            fi
        fi
    fi
    if [[ -n "$invoked_user" && "$invoked_user" != "$current_user" && "$can_read_invoked" == true ]]; then
        local invoked_home=""
        if command -v getent >/dev/null 2>&1; then
            invoked_home="$(getent passwd "$invoked_user" 2>/dev/null | cut -d: -f6)"
        fi
        if [[ -z "$invoked_home" ]]; then
            invoked_home="$(eval echo "~$invoked_user" 2>/dev/null || true)"
        fi
        if [[ -n "$invoked_home" && "$invoked_home" != "~$invoked_user" ]]; then
            local invoked_cronfile="${invoked_home%/}/cronfile"
            if [[ -r "$invoked_cronfile" ]]; then
                cron_add_source "cronfile:${invoked_user}"
                cron_add_lines "cronfile:${invoked_user}" "$invoked_user" "$(cat "$invoked_cronfile" 2>/dev/null || true)"
            fi
        fi
    fi
    if [[ "$invoked_snapshot_used" == true ]]; then
        can_read_invoked=true
    fi

    if [[ -n "$invoked_user" && "$invoked_user" != "$current_user" ]]; then
        if [[ "$can_read_invoked" == true ]]; then
            local enforced_label="${enforced_user:-$current_user}"
            cron_emit INFO "Cron scope: enforced=${enforced_label}, invoker=${invoked_user}"
        else
            local enforced_label="${enforced_user:-$current_user}"
            cron_emit INFO "Cron scope: enforced=${enforced_label}; invoker=${invoked_user} not checked (need sudo/root)"
        fi
    elif [[ -n "$enforced_user" && "$enforced_user" != "$current_user" ]]; then
        if [[ "$can_read_enforced" == true ]]; then
            cron_emit INFO "Cron scope: current user (${current_user}) + enforced user (${enforced_user})"
        else
            cron_emit INFO "Cron scope: current user (${current_user}) only; enforced user ${enforced_user} not checked (need sudo/root)"
        fi
    else
        cron_emit INFO "Cron scope: current user (${current_user})"
    fi

    if [[ ${#cron_sources[@]} -gt 0 ]]; then
        local sources_joined=""
        sources_joined="$(printf "%s, " "${cron_sources[@]}")"
        sources_joined="${sources_joined%, }"
        cron_emit INFO "Sources: ${sources_joined}"
    fi
    if [[ "${DEBUG:-false}" == true && -n "$instance_id" ]]; then
        cron_emit INFO "Instance ID: ${instance_id}"
    fi

    local base_clean="${INM_PATH_BASE_DIR%/}"
    local app_clean="${INM_INSTALLATION_PATH%/}"
    local env_clean="${INM_PATH_APP_ENV_FILE%/}"
    local instance_id="${INM_SELF_INSTANCE_ID:-}"
    local base_re="" app_re="" env_re="" scope_re=""
    [ -n "$base_clean" ] && base_re="$(escape_regex "$base_clean")"
    [ -n "$app_clean" ] && app_re="$(escape_regex "$app_clean")"
    [ -n "$env_clean" ] && env_re="$(escape_regex "$env_clean")"
    if [ -n "$base_re" ] && [ -n "$app_re" ]; then
        scope_re="${base_re}|${app_re}"
    else
        scope_re="${base_re}${app_re}"
    fi
    local inmanage_re="(inmanage(\\.sh)?|inm(\\.sh)?|notify-heartbeat|artisan[[:space:]]+schedule:run|core[[:space:]]+backup)"
    cron_line_matches_scope() {
        local line="$1"
        if [[ "$line" =~ INM_(SELF_)?INSTANCE_ID=([A-Za-z0-9._:-]+) ]]; then
            if [[ -n "$instance_id" && "${BASH_REMATCH[2]}" == "$instance_id" ]]; then
                return 0
            fi
            return 1
        fi
        if [[ -n "$scope_re" ]] && echo "$line" | grep -Eq "$scope_re"; then
            return 0
        fi
        if [[ -n "$env_re" ]] && echo "$line" | grep -Eq "$env_re"; then
            return 0
        fi
        if [[ -n "$base_re" ]] && echo "$line" | grep -Eq -- "--base-directory(=|[[:space:]])[\"']?${base_re}"; then
            return 0
        fi
        if [[ -n "$env_re" ]] && echo "$line" | grep -Eq -- "--env-file(=|[[:space:]])[\"']?${env_re}"; then
            return 0
        fi
        echo "$line" | grep -Eq "$inmanage_re"
    }

    cron_entry_schedule() {
        local line="$1"
        local f1 f2 f3 f4 f5
        read -r f1 f2 f3 f4 f5 _ <<< "$line"
        if [[ "$f1" == @* ]]; then
            printf "%s" "$f1"
            return 0
        fi
        if [[ -z "$f5" ]]; then
            printf "?"
            return 0
        fi
        if [[ "$f1" == "*" && "$f2" == "*" && "$f3" == "*" && "$f4" == "*" && "$f5" == "*" ]]; then
            printf "every minute"
            return 0
        fi
        if [[ "$f2" == "*" && "$f3" == "*" && "$f4" == "*" && "$f5" == "*" ]]; then
            if [[ "$f1" =~ ^\\*/([0-9]+)$ ]]; then
                printf "every %s min" "${BASH_REMATCH[1]}"
                return 0
            fi
            if [[ "$f1" =~ ^[0-5]?[0-9]$ ]]; then
                printf "hourly at :%02d" "$f1"
                return 0
            fi
        fi
        if [[ "$f3" == "*" && "$f4" == "*" && "$f5" == "*" && "$f1" =~ ^[0-5]?[0-9]$ && "$f2" =~ ^([01]?[0-9]|2[0-3])$ ]]; then
            printf "daily at %02d:%02d" "$f2" "$f1"
            return 0
        fi
        printf "%s %s %s %s %s" "$f1" "$f2" "$f3" "$f4" "$f5"
    }

    cron_entry_label() {
        local line="$1"
        local source="$2"
        local run_as="$3"
        local schedule
        schedule="$(cron_entry_schedule "$line")"
        local label="${source} @ ${schedule}"
        if [[ "$source" == cron.d* && -n "$run_as" && "$run_as" != "unknown" ]]; then
            label="${label} as ${run_as}"
        fi
        printf "%s" "$label"
    }

    cron_join_entries() {
        local -a entries=("$@")
        local joined=""
        joined="$(printf "%s; " "${entries[@]}")"
        printf "%s" "${joined%; }"
    }
    cron_entry_instance_hint() {
        local line="$1"
        local hint=""
        if [[ "$line" =~ INM_(SELF_)?INSTANCE_ID=([A-Za-z0-9._:-]+) ]]; then
            printf "id=%s" "${BASH_REMATCH[2]}"
            return 0
        fi
        if [[ "$line" =~ --base-directory(=|[[:space:]])([^[:space:]]+) ]]; then
            hint="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ --env-file(=|[[:space:]])([^[:space:]]+) ]]; then
            hint="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ [[:space:]]cd[[:space:]]+([^&;]+) ]]; then
            hint="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ (/[^[:space:]]+/artisan) ]]; then
            hint="${BASH_REMATCH[1]%/artisan}"
        fi
        hint="${hint#"${hint%%[![:space:]]*}"}"
        hint="${hint%"${hint##*[![:space:]]}"}"
        hint="${hint%/}"
        hint="${hint#\"}"
        hint="${hint%\"}"
        hint="${hint#\'}"
        hint="${hint%\'}"
        printf "%s" "$hint"
    }
    cron_entry_label_unknown() {
        local line="$1"
        local source="$2"
        local run_as="$3"
        local label
        label="$(cron_entry_label "$line" "$source" "$run_as")"
        local hint
        hint="$(cron_entry_instance_hint "$line")"
        if [[ -n "$hint" ]]; then
            label="${label} -> ${hint}"
        fi
        printf "%s" "$label"
    }

    local scheduler_work_running=false
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "artisan schedule:work" >/dev/null 2>&1 && scheduler_work_running=true
    elif command -v ps >/dev/null 2>&1; then
        # shellcheck disable=SC2009
        ps -ef 2>/dev/null | grep -q "[a]rtisan schedule:work" && scheduler_work_running=true
    fi

    local -a artisan_entries=()
    local -a backup_entries=()
    local -a heartbeat_entries=()
    local -a artisan_unknown=()
    local -a backup_unknown=()
    local -a heartbeat_unknown=()
    local unknown_hint_needed=false
    local idx line source run_as
    cron_line_in_scope() {
        local line="$1"
        if [[ "$line" =~ INM_(SELF_)?INSTANCE_ID=([A-Za-z0-9._:-]+) ]]; then
            if [[ -n "$instance_id" && "${BASH_REMATCH[2]}" == "$instance_id" ]]; then
                return 0
            fi
            return 1
        fi
        if [[ -n "$scope_re" ]] && echo "$line" | grep -Eq "$scope_re"; then
            return 0
        fi
        if [[ -n "$env_re" ]] && echo "$line" | grep -Eq "$env_re"; then
            return 0
        fi
        if [[ -n "$base_re" ]] && echo "$line" | grep -Eq -- "--base-directory(=|[[:space:]])[\"']?${base_re}"; then
            return 0
        fi
        if [[ -n "$env_re" ]] && echo "$line" | grep -Eq -- "--env-file(=|[[:space:]])[\"']?${env_re}"; then
            return 0
        fi
        return 1
    }

    cron_job_match() {
        local job="$1"
        local line="$2"
        case "$job" in
            artisan)
                if echo "$line" | grep -Eq "artisan[[:space:]]+schedule:run"; then
                    return 0
                fi
                if cron_line_matches_scope "$line" && echo "$line" | grep -Eq "schedule:run"; then
                    return 0
                fi
                ;;
            backup)
                if echo "$line" | grep -Eq "(inmanage(\\.sh)?|inm(\\.sh)?) .*core[[:space:]]+backup"; then
                    return 0
                fi
                if cron_line_matches_scope "$line" && echo "$line" | grep -Ei "core[[:space:]]+backup"; then
                    return 0
                fi
                ;;
            heartbeat)
                if echo "$line" | grep -Eq "notify-heartbeat"; then
                    return 0
                fi
                if cron_line_matches_scope "$line" && echo "$line" | grep -Ei "notify-heartbeat"; then
                    return 0
                fi
                ;;
        esac
        return 1
    }
    for idx in "${!cron_entry_line[@]}"; do
        line="${cron_entry_line[$idx]}"
        source="${cron_entry_source[$idx]}"
        run_as="${cron_entry_user[$idx]}"
        if cron_job_match "artisan" "$line"; then
            if cron_line_in_scope "$line"; then
                artisan_entries+=("$(cron_entry_label "$line" "$source" "$run_as")")
            else
                artisan_unknown+=("$(cron_entry_label_unknown "$line" "$source" "$run_as")")
            fi
        fi
        if cron_job_match "backup" "$line"; then
            if cron_line_in_scope "$line"; then
                backup_entries+=("$(cron_entry_label "$line" "$source" "$run_as")")
            else
                backup_unknown+=("$(cron_entry_label_unknown "$line" "$source" "$run_as")")
            fi
        fi
        if cron_job_match "heartbeat" "$line"; then
            if cron_line_in_scope "$line"; then
                heartbeat_entries+=("$(cron_entry_label "$line" "$source" "$run_as")")
            else
                heartbeat_unknown+=("$(cron_entry_label_unknown "$line" "$source" "$run_as")")
            fi
        fi
    done

    if (( ${#artisan_entries[@]} > 0 )); then
        if (( ${#artisan_entries[@]} > 1 )); then
            cron_emit WARN "artisan schedule: concurrent jobs detected (${#artisan_entries[@]}): $(cron_join_entries "${artisan_entries[@]}")"
        else
            cron_emit OK "artisan schedule:run detected: ${artisan_entries[0]}"
        fi
    elif [[ "$scheduler_work_running" == true ]]; then
        cron_emit OK "artisan scheduler running (schedule:work)"
    elif (( ${#artisan_unknown[@]} > 0 )); then
        cron_emit WARN "artisan schedule: jobs for another instance (${#artisan_unknown[@]}): $(cron_join_entries "${artisan_unknown[@]}")"
        unknown_hint_needed=true
    else
        cron_emit WARN "artisan schedule: no jobs detected"
    fi

    if (( ${#backup_entries[@]} > 0 )); then
        if (( ${#backup_entries[@]} > 1 )); then
            cron_emit WARN "backup: concurrent jobs detected (${#backup_entries[@]}): $(cron_join_entries "${backup_entries[@]}")"
        else
            cron_emit OK "backup detected: ${backup_entries[0]}"
        fi
    elif (( ${#backup_unknown[@]} > 0 )); then
        cron_emit WARN "backup: jobs for another instance (${#backup_unknown[@]}): $(cron_join_entries "${backup_unknown[@]}")"
        unknown_hint_needed=true
    else
        if [[ -n "${INM_CRON_BACKUP_TIME:-}" ]]; then
            cron_emit WARN "backup: no jobs detected"
        else
            cron_emit INFO "backup: not configured for this instance"
        fi
    fi

    if (( ${#heartbeat_entries[@]} > 0 )); then
        if (( ${#heartbeat_entries[@]} > 1 )); then
            cron_emit WARN "heartbeat: concurrent jobs detected (${#heartbeat_entries[@]}): $(cron_join_entries "${heartbeat_entries[@]}")"
        else
            cron_emit OK "heartbeat detected: ${heartbeat_entries[0]}"
        fi
    elif (( ${#heartbeat_unknown[@]} > 0 )); then
        cron_emit WARN "heartbeat: jobs for another instance (${#heartbeat_unknown[@]}): $(cron_join_entries "${heartbeat_unknown[@]}")"
        unknown_hint_needed=true
    else
        local hb_enabled=false
        local hb_targets_email=false
        local notify_targets="${INM_NOTIFY_TARGETS_LIST:-}"
        notify_targets="${notify_targets,,}"
        notify_targets="${notify_targets// /}"
        if [[ -n "$notify_targets" && ",${notify_targets}," == *",email,"* ]]; then
            hb_targets_email=true
        fi
        if args_is_true "${INM_NOTIFY_HEARTBEAT_ENABLE:-false}" && [[ "$hb_targets_email" == true ]]; then
            hb_enabled=true
        fi
        if [[ "$hb_enabled" == true ]]; then
            cron_emit WARN "heartbeat: no jobs detected"
        else
            if args_is_true "${INM_NOTIFY_HEARTBEAT_ENABLE:-false}" && [[ "$hb_targets_email" != true ]]; then
                cron_emit INFO "heartbeat: not configured (INM_NOTIFY_TARGETS_LIST excludes email)"
            else
                cron_emit INFO "heartbeat: not enabled for this instance"
            fi
        fi
    fi
    if [[ "$unknown_hint_needed" == true ]]; then
        cron_emit INFO "Hint: add INM_SELF_INSTANCE_ID=${instance_id} to manual cron lines or run 'inm core cron install' so jobs map to this instance."
    fi
}
