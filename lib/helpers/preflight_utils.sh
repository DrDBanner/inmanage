#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__PREFLIGHT_UTILS_LOADED:-} ]] && return
__PREFLIGHT_UTILS_LOADED=1

preflight_helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${preflight_helpers_dir}/update_notice.sh" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${preflight_helpers_dir}/update_notice.sh"
fi

# ---------------------------------------------------------------------
# normalize_check_tag()
# Normalize user-supplied tag to canonical preflight tag.
# Consumes: args: raw.
# Computes: canonical tag string.
# Returns: tag on stdout (empty if unknown).
# ---------------------------------------------------------------------
normalize_check_tag() {
    local raw="$1"
    local tag="${raw^^}"
    tag="${tag//[^A-Z0-9]/}"
    case "$tag" in
        CLI) echo "CLI" ;;
        SYS|SYSTEM) echo "SYS" ;;
        FS|FILESYSTEM|DISK) echo "FS" ;;
        ENVCLI|ENVCL|CLICONFIG) echo "ENVCLI" ;;
        ENVAPP|APPENV) echo "ENVAPP" ;;
        CMD|COMMAND|COMMANDS|TOOLS|CLICMD|CLICMDS|CLICOMMAND|CLICOMMANDS) echo "CMD" ;;
        WEB|WEBSERVER) echo "WEB" ;;
        PHP) echo "PHP" ;;
        EXT|EXTENSIONS|PHPEXT) echo "EXT" ;;
        WEBPHP|WEBPH) echo "WEBPHP" ;;
        NET|NETWORK|DNS) echo "NET" ;;
        MAIL|SMTP|EMAIL) echo "MAIL" ;;
        DB|DATABASE|MYSQL|MARIADB) echo "DB" ;;
        APP|APPLICATION) echo "APP" ;;
        PERM|PERMISSION|PERMISSIONS) echo "PERM" ;;
        CRON|SCHEDULER) echo "CRON" ;;
        LOG|LOGS|EVENT|EVENTS) echo "LOG" ;;
        SNAPPDF|SNAPDF|PDF) echo "SNAPPDF" ;;
        *) echo "" ;;
    esac
}

# ---------------------------------------------------------------------
# preflight_compute_context()
# Compute enforced owner, current user, and enforcement capability.
# Consumes: args: enforced_user, enforced_group, owner_ref, can_enforce_ref, current_user_ref, cli_config_ref; env: INM_SELF_ENV_FILE.
# Computes: owner string, can_enforce boolean, current user, CLI config presence.
# Returns: 0 after assignment.
# ---------------------------------------------------------------------
preflight_compute_context() {
    local enforced_user="$1"
    local enforced_group="$2"
    local -n owner_ref="$3"
    local -n can_enforce_ref="$4"
    local -n current_user_ref="$5"
    local -n cli_config_ref="$6"

    current_user_ref="$(id -un 2>/dev/null || true)"
    cli_config_ref=false
    if [[ -n "${INM_SELF_ENV_FILE:-}" && -f "${INM_SELF_ENV_FILE:-}" ]]; then
        cli_config_ref=true
    fi

    owner_ref=""
    if [ -n "$enforced_user" ]; then
        local group="$enforced_group"
        if [ -z "$group" ]; then
            group="$(id -gn "$enforced_user" 2>/dev/null || true)"
            [[ -z "$group" ]] && group="$enforced_user"
        fi
        owner_ref="${enforced_user}:${group}"
    fi

    can_enforce_ref=false
    if [ -n "$enforced_user" ] && { [ "$EUID" -eq 0 ] || [ "$current_user_ref" = "$enforced_user" ]; }; then
        can_enforce_ref=true
    fi

    : "$owner_ref" "$can_enforce_ref" "$current_user_ref" "$cli_config_ref"
}

# ---------------------------------------------------------------------
# preflight_hydrate_app_url()
# Populate APP_URL from the app .env if missing.
# Consumes: env: APP_URL, INM_ENV_FILE.
# Computes: APP_URL if empty and .env contains it.
# Returns: 0 after attempting hydration.
# ---------------------------------------------------------------------
preflight_hydrate_app_url() {
    if [ -z "${APP_URL:-}" ] && [ -f "${INM_ENV_FILE:-}" ]; then
        local app_url
        app_url=$(grep -E '^APP_URL=' "$INM_ENV_FILE" 2>/dev/null | head -n1 | sed -E 's/^APP_URL=//' | tr -d '"'\'' ')
        if [ -n "$app_url" ]; then
            APP_URL="$app_url"
        fi
    fi
}

# ---------------------------------------------------------------------
# extract_cron_time()
# Parse HH:MM from a cron line.
# Consumes: args: line.
# Computes: time string.
# Returns: time on stdout (empty if invalid).
# ---------------------------------------------------------------------
extract_cron_time() {
    local line="$1"
    local min hour
    min="$(awk '{print $1}' <<<"$line")"
    hour="$(awk '{print $2}' <<<"$line")"
    if [[ "$min" =~ ^[0-5]?[0-9]$ && "$hour" =~ ^([01]?[0-9]|2[0-3])$ ]]; then
        printf "%02d:%02d" "$hour" "$min"
    fi
}

# ---------------------------------------------------------------------
# format_check_label()
# Map check tag to display label.
# Consumes: args: tag.
# Computes: human label.
# Returns: label on stdout.
# ---------------------------------------------------------------------
format_check_label() {
    case "$1" in
        CLI) echo "CLI" ;;
        SYS) echo "System" ;;
        ENVCLI) echo "ENV CLI" ;;
        APP) echo "App" ;;
        ENVAPP) echo "ENV APP" ;;
        CMD) echo "CLI Commands" ;;
        NET) echo "Network" ;;
        MAIL) echo "Mail Route" ;;
        WEB) echo "Web Server" ;;
        PHP) echo "PHP CLI" ;;
        EXT) echo "PHP Extensions" ;;
        WEBPHP) echo "PHP Web" ;;
        FS) echo "Filesystem" ;;
        DB) echo "Database" ;;
        CRON) echo "Cron" ;;
        SNAPPDF) echo "Snappdf" ;;
        *) echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------
# preflight_apply_filter()
# Apply include/exclude filters to check tags.
# Consumes: args: filter, mode; globals: PF_ALLOW, PF_DENY, unknown_checks; deps: normalize_check_tag.
# Computes: allow/deny maps and unknown tags list.
# Returns: 0 after applying.
# ---------------------------------------------------------------------
preflight_apply_filter() {
    local filter="$1"
    local mode="$2"
    local c norm
    IFS=',' read -ra tmp_checks <<<"$filter"
    for c in "${tmp_checks[@]}"; do
        norm="$(normalize_check_tag "$c")"
        if [[ -n "$norm" ]]; then
            if [[ "$mode" == "allow" ]]; then
                PF_ALLOW["${norm}"]=1
            else
                PF_DENY["${norm}"]=1
            fi
        else
            unknown_checks+=("$c")
        fi
    done
}

# ---------------------------------------------------------------------
# should_run()
# Decide if a check tag should run based on filters.
# Consumes: args: tag; globals: PF_ALLOW, PF_DENY, checks_filter.
# Computes: filter decision.
# Returns: 0 if allowed, 1 if denied.
# ---------------------------------------------------------------------
should_run() {
    local tag="$1"
    if [[ -n "${PF_DENY[$tag]:-}" ]]; then
        return 1
    fi
    if [[ -z "${checks_filter:-}" ]]; then
        return 0
    fi
    [[ -n "${PF_ALLOW[$tag]:-}" ]]
}

# ---------------------------------------------------------------------
# add_result()
# Append a result entry to the preflight output arrays.
# Consumes: args: status, tag, detail; globals: PF_STATUS, PF_CHECK, PF_DETAIL, ok, warn, err, checks_filter, PF_ALLOW.
# Computes: result arrays and counters.
# Returns: 0 after adding.
# ---------------------------------------------------------------------
add_result() {
    local status="$1"
    local tag="$2"
    local detail="$3"
    if [[ -n "${PF_DENY[$tag]:-}" ]]; then
        return 0
    fi
    if [[ -n "${checks_filter:-}" && -z "${PF_ALLOW[$tag]:-}" ]]; then
        return 0
    fi
    PF_STATUS+=("$status")
    PF_CHECK+=("$tag")
    PF_DETAIL+=("$detail")
    case "$status" in
        OK)   ((ok++));;
        WARN) ((warn++));;
        ERR)  ((err++));;
        *)    ;;
    esac
}

# ---------------------------------------------------------------------
# preflight_emit_cli_info()
# Emit CLI metadata and update status for preflight output.
# Consumes: args: add_fn, fast, skip_github; env: INM_*; deps: git_collect_info/git_origin_url/git_local_head/git_remote_head.
# Computes: CLI source/version/update lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_emit_cli_info() {
    local add_fn="$1"
    local fast="${2:-false}"
    local skip_github="${3:-false}"
    local update_due="${4:-true}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    cli_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "CLI" "$detail"
        else
            case "$status" in
                OK) log info "[CLI] $detail" ;;
                WARN) log warn "[CLI] $detail" ;;
                ERR) log err "[CLI] $detail" ;;
                INFO) log info "[CLI] $detail" ;;
                *) log info "[CLI] $detail" ;;
            esac
        fi
    }

    local -A cli_info=()
    cli_collect_info cli_info

    local cli_root="${cli_info[root]}"
    cli_emit INFO "CLI: $cli_root"

    if [[ "${cli_info[git_present]}" == true ]]; then
        cli_emit INFO "Source: git checkout (branch=${cli_info[branch]} commit=${cli_info[commit]}${cli_info[dirty]})"
        if echo "${cli_info[git_error]:-}" | grep -qi "dubious ownership"; then
            cli_emit WARN "Git ownership check blocked access. Run to fix: git config --global --add safe.directory $cli_root"
        elif echo "${cli_info[git_error]:-}" | grep -qi "permission denied"; then
            cli_emit WARN "Git metadata not readable at $cli_root (try: sudo or adjust ownership)."
        fi
        [[ -n "${cli_info[commit_date]:-}" ]] && cli_emit INFO "Last commit date: ${cli_info[commit_date]}"
    elif [[ -n "${cli_info[commit]:-}" || -n "${cli_info[version]:-}" ]]; then
        local snap_branch="${cli_info[branch]:-unknown}"
        local snap_commit="${cli_info[commit]:-unknown}"
        cli_emit INFO "Source: snapshot (branch=${snap_branch} commit=${snap_commit})"
    else
        cli_emit WARN "Source: no git metadata (tarball/snapshot install)"
    fi
    if [[ -n "${cli_info[version]:-}" ]]; then
        cli_emit INFO "Version file: ${cli_info[version]}"
    fi

    cli_emit INFO "Install mode: ${cli_info[install_mode]:-unknown} (switch with: inm self switch-mode)"

    if [[ -n "${cli_info[newest_file]:-}" ]]; then
        cli_emit INFO "Newest file mtime: ${cli_info[newest_mtime_short]} (${cli_info[newest_file]})"
        if [[ -n "${cli_info[inmanage_mtime_short]:-}" && "${cli_info[newest_file]}" != "inmanage.sh" ]]; then
            cli_emit INFO "inmanage.sh modified: ${cli_info[inmanage_mtime_short]}"
        fi
    elif [[ -n "${cli_info[inmanage_mtime_short]:-}" ]]; then
        cli_emit INFO "inmanage.sh modified: ${cli_info[inmanage_mtime_short]}"
    fi

    if [ "$fast" != true ] && [ "$skip_github" != true ]; then
        if [[ "$update_due" != true ]]; then
            cli_emit INFO "CLI update check deferred (last check <24h; use --force to refresh)"
            return 0
        fi
        if declare -F update_notice_mark_checked >/dev/null 2>&1; then
            update_notice_mark_checked
        fi
        if [[ "${cli_info[git_present]}" == true ]]; then
            local local_commit_full remote_commit remote_short local_short
            if git_origin_url "$cli_root" "" >/dev/null; then
                git_local_head "$cli_root" local_commit_full || local_commit_full=""
                local ref="${cli_info[branch]:-}"
                if [[ -z "$ref" || "$ref" == "unknown" ]]; then
                    ref="HEAD"
                fi
                git_remote_head "$cli_root" "$ref" remote_commit || remote_commit=""
                if [ -n "$local_commit_full" ] && [ -n "$remote_commit" ]; then
                    if [ "$local_commit_full" != "$remote_commit" ]; then
                        remote_short="${remote_commit:0:7}"
                        local_short="${cli_info[commit]:-}"
                        if [ -z "$local_short" ] || [ "$local_short" = "unknown" ]; then
                            local_short="${local_commit_full:0:7}"
                        fi
                        cli_emit INFO "CLI update available: ${local_short} -> ${remote_short} (run: inm self update)"
                        if declare -F update_notice_set >/dev/null 2>&1; then
                            update_notice_set "cli" "info" \
                                "CLI update available: ${local_short} -> ${remote_short} (run: inm self update)"
                        fi
                    else
                        cli_emit OK "CLI up to date"
                        if declare -F update_notice_clear >/dev/null 2>&1; then
                            update_notice_clear "cli"
                        fi
                    fi
                else
                    cli_emit INFO "CLI update check skipped (origin unreachable)"
                fi
            else
                cli_emit INFO "CLI update check skipped (no git origin)"
            fi
        fi
    else
        cli_emit INFO "CLI update check skipped (--skip-github/--fast)"
    fi
}

# ---------------------------------------------------------------------
# preflight_emit_commands()
# Emit CLI command availability for preflight output.
# Consumes: args: add_fn, mode; deps: check_commands_list/check_commands_missing/check_db_tools_preflight.
# Computes: CLI command status lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_emit_commands() {
    local add_fn="$1"
    local mode="${2:-preflight}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    cmd_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "CMD" "$detail"
        else
            case "$status" in
                OK) log info "[CMD] $detail" ;;
                WARN) log warn "[CMD] $detail" ;;
                ERR) log err "[CMD] $detail" ;;
                INFO) log info "[CMD] $detail" ;;
                *) log info "[CMD] $detail" ;;
            esac
        fi
    }

    local req_cmds=()
    mapfile -t req_cmds < <(check_commands_list "$mode")

    local missing_cmds=()
    mapfile -t missing_cmds < <(check_commands_missing "$mode")

    local -A missing_set=()
    local m
    for m in "${missing_cmds[@]}"; do
        missing_set["$m"]=1
    done

    local cmd
    for cmd in "${req_cmds[@]}"; do
        if [[ "$cmd" == "sha256sum" ]]; then
            if [[ -n "${missing_set[sha256sum/shasum/sha256]:-}" ]]; then
                cmd_emit ERR "sha256sum/shasum/sha256 missing"
            else
                cmd_emit OK "sha256sum/shasum/sha256"
            fi
            continue
        fi
        if [[ -n "${missing_set[$cmd]:-}" ]]; then
            cmd_emit ERR "${cmd} missing"
        else
            cmd_emit OK "$cmd"
        fi
    done

    check_db_tools_preflight "$add_fn" "CMD"
}

# ---------------------------------------------------------------------
# preflight_require_commands()
# Fail fast if required commands are missing.
# Consumes: args: label, mode; deps: check_commands_missing.
# Computes: missing command list.
# Returns: 0 if ok, 1 if missing.
# ---------------------------------------------------------------------
preflight_require_commands() {
    local label="$1"
    local mode="${2:-preflight}"
    local -a missing_cmds=()
    mapfile -t missing_cmds < <(check_commands_missing "$mode")
    if [ ${#missing_cmds[@]} -gt 0 ]; then
        log err "[${label}] Missing required CLI commands: ${missing_cmds[*]}"
        log info "[${label}] Please install missing commands to proceed."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# preflight_emit_env_cli()
# Emit CLI env configuration summary for preflight output.
# Consumes: args: add_fn; env: INM_*; deps: args_is_true.
# Computes: CLI env summary lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_emit_env_cli() {
    local add_fn="$1"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    env_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "ENVCLI" "$detail"
        else
            case "$status" in
                OK) log info "[ENVCLI] $detail" ;;
                WARN) log warn "[ENVCLI] $detail" ;;
                ERR) log err "[ENVCLI] $detail" ;;
                INFO) log info "[ENVCLI] $detail" ;;
                *) log info "[ENVCLI] $detail" ;;
            esac
        fi
    }

    if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "$INM_SELF_ENV_FILE" ]; then
        if [[ -z "${INM_INSTANCE_ID:-}" ]]; then
            env_resolve_instance_id "${INM_BASE_DIRECTORY:-}" "${INM_ENV_FILE:-}" >/dev/null 2>&1 || true
        fi
        local cli_keys=(INM_INSTANCE_ID INM_ENFORCED_USER INM_BASE_DIRECTORY INM_INSTALLATION_DIRECTORY INM_BACKUP_DIRECTORY INM_CACHE_GLOBAL_DIRECTORY INM_CACHE_LOCAL_DIRECTORY INM_HISTORY_LOG_FILE INM_HISTORY_LOG_MAX_SIZE INM_HISTORY_LOG_ROTATE)
        local k
        for k in "${cli_keys[@]}"; do
            local v="${!k}"
            env_emit INFO "${k}=${v:-<unset>}"
        done
        local notify_enabled_raw="${INM_NOTIFY_ENABLED:-false}"
        local notify_enabled=false
        args_is_true "$notify_enabled_raw" && notify_enabled=true
        local notify_targets="${INM_NOTIFY_TARGETS:-<unset>}"
        local notify_level="${INM_NOTIFY_LEVEL:-ERR}"
        local notify_noninteractive="${INM_NOTIFY_NONINTERACTIVE_ONLY:-true}"
        env_emit INFO "NOTIFY: enabled=${notify_enabled_raw} targets=${notify_targets} level=${notify_level} noninteractive=${notify_noninteractive}"

        if [[ "$notify_enabled" == true ]]; then
            local email_to_set="false"
            local email_from_set="false"
            local webhook_set="false"
            [[ -n "${INM_NOTIFY_EMAIL_TO:-}" ]] && email_to_set="true"
            [[ -n "${INM_NOTIFY_EMAIL_FROM:-}" || -n "${INM_NOTIFY_EMAIL_FROM_NAME:-}" ]] && email_from_set="true"
            [[ -n "${INM_NOTIFY_WEBHOOK_URL:-}" ]] && webhook_set="true"
            if [[ "$email_to_set" == "true" || "$email_from_set" == "true" || "$webhook_set" == "true" ]]; then
                env_emit INFO "NOTIFY_CONTACTS: email_to=${email_to_set} email_from=${email_from_set} webhook=${webhook_set}"
            fi

            local hb_enabled_raw="${INM_NOTIFY_HEARTBEAT_ENABLED:-false}"
            local hb_enabled=false
            args_is_true "$hb_enabled_raw" && hb_enabled=true
            if [[ "$hb_enabled" == true ]]; then
                local hb_time="${INM_NOTIFY_HEARTBEAT_TIME:-06:00}"
                local hb_level="${INM_NOTIFY_HEARTBEAT_LEVEL:-ERR}"
                local hb_format="${INM_NOTIFY_HEARTBEAT_FORMAT:-}"
                local hb_line="HEARTBEAT: enabled=true time=${hb_time} level=${hb_level}"
                if [[ -n "$hb_format" ]]; then
                    hb_line+=" format=${hb_format}"
                else
                    local hb_detail="${INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL:-auto}"
                    hb_line+=" detail=${hb_detail}"
                fi
                if [[ -n "${INM_NOTIFY_HEARTBEAT_INCLUDE:-}" ]]; then
                    hb_line+=" include=${INM_NOTIFY_HEARTBEAT_INCLUDE}"
                fi
                if [[ -n "${INM_NOTIFY_HEARTBEAT_EXCLUDE:-}" ]]; then
                    hb_line+=" exclude=${INM_NOTIFY_HEARTBEAT_EXCLUDE}"
                fi
                env_emit INFO "$hb_line"
            else
                env_emit INFO "HEARTBEAT: enabled=false"
            fi
        fi
    else
        env_emit WARN "Not installed (yet) – CLI env missing (${INM_SELF_ENV_FILE:-unset})"
    fi
}

# ---------------------------------------------------------------------
# preflight_emit_env_app()
# Emit app env summary for preflight output.
# Consumes: args: add_fn; env: INM_ENV_FILE; deps: read_env_value.
# Computes: app env key summary.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_emit_env_app() {
    local add_fn="$1"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    env_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "ENVAPP" "$detail"
        else
            case "$status" in
                OK) log info "[ENVAPP] $detail" ;;
                WARN) log warn "[ENVAPP] $detail" ;;
                ERR) log err "[ENVAPP] $detail" ;;
                INFO) log info "[ENVAPP] $detail" ;;
                *) log info "[ENVAPP] $detail" ;;
            esac
        fi
    }

    if [ -n "${INM_ENV_FILE:-}" ] && [ -f "$INM_ENV_FILE" ]; then
        local app_keys=(APP_NAME APP_URL PDF_GENERATOR APP_DEBUG)
        local k
        for k in "${app_keys[@]}"; do
            local v
            v=$(read_env_value "$INM_ENV_FILE" "$k")
            env_emit INFO "${k}=${v:-<unset>}"
        done
    else
        env_emit WARN "Not installed (yet) – app .env missing (${INM_ENV_FILE:-unset})"
    fi
}

# ---------------------------------------------------------------------
# preflight_emit_filesystem()
# Emit filesystem checks for preflight output.
# Consumes: args: add_fn, cli_config_present, enforced_owner; env: INM_*; deps: fs_path_size/fs_path_size_timeout/preflight_check_cache_dir/preflight_warn_cache_world_writable/preflight_fs_du_timeout/fs_user_can_write.
# Computes: disk and directory writable status lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_emit_filesystem() {
    local add_fn="$1"
    local cli_config_present="${2:-false}"
    local enforced_owner="${3:-}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    fs_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "FS" "$detail"
        else
            case "$status" in
                OK) log info "[FS] $detail" ;;
                WARN) log warn "[FS] $detail" ;;
                ERR) log err "[FS] $detail" ;;
                INFO) log info "[FS] $detail" ;;
                *) log info "[FS] $detail" ;;
            esac
        fi
    }

    if [ -n "${INM_BASE_DIRECTORY:-}" ] && df -h "$INM_BASE_DIRECTORY" >/dev/null 2>&1; then
        local diskline=""
        local df_out="" used="" avail="" mount=""
        df_out="$(df -hP "$INM_BASE_DIRECTORY" 2>/dev/null | awk 'NR==2{print $3" "$4" "$6}')" || true
        read -r used avail mount <<<"$df_out"
        if [[ "$used" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]]; then
            df_out="$(df -h "$INM_BASE_DIRECTORY" 2>/dev/null | awk 'NR==2{print $3" "$4" "$6}')" || true
            read -r used avail mount <<<"$df_out"
        fi
        if [[ -n "$used" && -n "$avail" && -n "$mount" ]]; then
            diskline="avail:${avail} used:${used} mount:${mount}"
            fs_emit INFO "$diskline (Disk @base)"
        fi
    fi

    local fs_items=()
    if [ "$cli_config_present" = true ]; then
        fs_items=(
            "$INM_BASE_DIRECTORY|Base dir"
            "$INM_INSTALLATION_PATH|App dir"
            "$INM_BACKUP_DIRECTORY|Backup dir"
        )
    else
        fs_emit INFO "Not installed (yet) – base/app/backup checks skipped (CLI config missing)"
    fi
    local entry
    local enforced_user=""
    if [ -n "$enforced_owner" ]; then
        enforced_user="${enforced_owner%%:*}"
    fi
    for entry in "${fs_items[@]}"; do
        local dir label
        dir="${entry%%|*}"
        label="${entry#*|}"
        [ -z "$dir" ] && continue
        if [[ ! -d "$dir" ]]; then
            fs_emit WARN "Missing: $dir ($label)"
            continue
        fi
        local sz=""
        local base_dir="${INM_BASE_DIRECTORY%/}"
        if [ -d "$dir" ]; then
            local du_timeout du_rc=0
            du_timeout="$(preflight_fs_du_timeout "$dir")"
            sz="$(fs_path_size_timeout "$dir" "$du_timeout")"
            du_rc=$?
            if [ "$du_rc" -eq 124 ]; then
                log debug "[FS] Size check timed out for $dir; skipping size."
            fi
        fi
        if [[ -z "$sz" && -n "$base_dir" && "${dir%/}" == "$base_dir" ]]; then
            sz="$(fs_path_size "$dir")"
        fi
        local check_user="${enforced_user:-}"
        if [ -z "$check_user" ]; then
            check_user="$(id -un 2>/dev/null || true)"
        fi
        if fs_user_can_write "$dir" "$check_user" true; then
            local detail="Writable: $dir ($label)"
            [[ -n "$sz" ]] && detail+=" (Size: $sz)"
            fs_emit OK "$detail"
        else
            local hint="$label not writable: $dir"
            if [ -n "${enforced_owner:-}" ]; then
                hint+=" (hint: chown -R ${enforced_owner} \"$dir\" or run 'inm core health --fix-permissions')"
            fi
            fs_emit ERR "$hint"
        fi
    done

    local cache_global_state="unset"
    local cache_local_state="unset"
    local cache_global_detail=""
    local cache_local_detail=""
    local cache_global_world_writable=false
    local cache_local_world_writable=false
    local cache_global_mode=""
    local cache_local_mode=""

    local gc_path=""
    local lc_path=""
    if [ -n "${INM_CACHE_GLOBAL_DIRECTORY:-}" ]; then
        gc_path="$(expand_path_vars "$INM_CACHE_GLOBAL_DIRECTORY")"
        preflight_check_cache_dir "$gc_path" "global" "INM_CACHE_GLOBAL_DIRECTORY" \
            cache_global_state cache_global_detail cache_global_mode cache_global_world_writable
    fi

    if [ -n "${INM_CACHE_LOCAL_DIRECTORY:-}" ]; then
        lc_path="$(expand_path_vars "$INM_CACHE_LOCAL_DIRECTORY")"
        preflight_check_cache_dir "$lc_path" "local" "INM_CACHE_LOCAL_DIRECTORY" \
            cache_local_state cache_local_detail cache_local_mode cache_local_world_writable
    fi

    local cache_any_ok=false
    if [ "$cache_global_state" = "ok" ] || [ "$cache_local_state" = "ok" ]; then
        cache_any_ok=true
    fi

    if [ "$cache_global_state" = "ok" ]; then
        fs_emit OK "$cache_global_detail"
        if [ "$cache_global_world_writable" = true ]; then
            preflight_warn_cache_world_writable "global" "$gc_path" "$cache_global_mode"
        fi
    elif [ "$cache_global_state" = "missing" ]; then
        fs_emit WARN "$cache_global_detail"
    elif [ "$cache_global_state" = "fail" ]; then
        if [ "$cache_any_ok" = true ]; then
            fs_emit INFO "${cache_global_detail} (local cache writable; consider fixing global cache for shared use)"
        else
            fs_emit ERR "${cache_global_detail} (no writable cache directories)"
        fi
    fi

    if [ "$cache_local_state" = "ok" ]; then
        fs_emit OK "$cache_local_detail"
        if [ "$cache_local_world_writable" = true ]; then
            preflight_warn_cache_world_writable "local" "$lc_path" "$cache_local_mode"
        fi
    elif [ "$cache_local_state" = "missing" ]; then
        fs_emit WARN "$cache_local_detail"
    elif [ "$cache_local_state" = "fail" ]; then
        if [ "$cache_any_ok" = true ]; then
            fs_emit INFO "${cache_local_detail} (global cache writable; consider fixing local cache for speed)"
        else
            fs_emit ERR "${cache_local_detail} (no writable cache directories)"
        fi
    fi
}

# ---------------------------------------------------------------------
# preflight_emit_network()
# Emit network reachability checks for preflight output.
# Consumes: args: add_fn, fast, skip_github; env: APP_URL; deps: http_head.
# Computes: GitHub and APP_URL reachability lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_emit_network() {
    local add_fn="$1"
    local fast="${2:-false}"
    local skip_github="${3:-false}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    net_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "NET" "$detail"
        else
            case "$status" in
                OK) log info "[NET] $detail" ;;
                WARN) log warn "[NET] $detail" ;;
                ERR) log err "[NET] $detail" ;;
                INFO) log info "[NET] $detail" ;;
                *) log info "[NET] $detail" ;;
            esac
        fi
    }

    if [ "$fast" != true ] && [ "$skip_github" != true ]; then
        local gh_ok=false
        http_head "https://github.com" gh_ok ""
        if [[ "$gh_ok" == true ]]; then
            net_emit OK "GitHub reachable"
        else
            net_emit WARN "GitHub not reachable"
        fi
    fi

    if [ -n "${APP_URL:-}" ]; then
        local host_only app_url_trim
        app_url_trim="${APP_URL%/}"
        host_only=$(echo "$app_url_trim" | sed -E 's@https?://([^/]+).*@\1@')
        if [ -n "$host_only" ]; then
            if getent hosts "$host_only" >/dev/null 2>&1 || host "$host_only" >/dev/null 2>&1; then
                net_emit INFO "DNS resolves: $host_only"
            else
                net_emit WARN "DNS failed: $host_only"
            fi
            local curl_ok=false
            local curl_insecure=false
            http_head "$app_url_trim" curl_ok curl_insecure
            if [[ "$curl_ok" == true ]]; then
                if [[ "$curl_insecure" == true ]]; then
                    net_emit WARN "Webserver certificate does not match URL: $app_url_trim"
                else
                    net_emit INFO "APP_URL reachable: $app_url_trim"
                fi
            fi
            if [ "$curl_ok" != true ]; then
                local http_fallback="${app_url_trim/https:\/\//http://}"
                local http_ok=false
                http_head "$http_fallback" http_ok ""
                if [[ "$http_ok" == true ]]; then
                    net_emit WARN "HTTPS failed; reachable via HTTP: $http_fallback"
                else
                    net_emit WARN "APP_URL not reachable: $app_url_trim"
                fi
            fi
        fi
    fi
}

# ---------------------------------------------------------------------
# preflight_emit_mail()
# Emit SMTP reachability checks for preflight output.
# Consumes: args: add_fn; env: INM_ENV_FILE/DEBUG; deps: read_env_value.
# Computes: SMTP reachability lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_emit_mail() {
    local add_fn="$1"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    mail_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "MAIL" "$detail"
        else
            case "$status" in
                OK) log info "[MAIL] $detail" ;;
                WARN) log warn "[MAIL] $detail" ;;
                ERR) log err "[MAIL] $detail" ;;
                INFO) log info "[MAIL] $detail" ;;
                *) log info "[MAIL] $detail" ;;
            esac
        fi
    }

    if [ -n "${INM_ENV_FILE:-}" ] && [ -f "$INM_ENV_FILE" ]; then
        local smtp_mailer smtp_host smtp_port
        smtp_mailer=$(read_env_value "$INM_ENV_FILE" "MAIL_MAILER")
        if [ -z "$smtp_mailer" ]; then
            smtp_mailer=$(read_env_value "$INM_ENV_FILE" "MAIL_DRIVER")
        fi
        smtp_host=$(read_env_value "$INM_ENV_FILE" "MAIL_HOST")
        smtp_port=$(read_env_value "$INM_ENV_FILE" "MAIL_PORT")
        if [ -n "$smtp_mailer" ] && [ "$smtp_mailer" != "smtp" ]; then
            mail_emit INFO "Mail: ${smtp_mailer} currently active (SMTP check skipped)"
        elif [ -n "$smtp_host" ]; then
            smtp_port="${smtp_port:-587}"
            local smtp_out smtp_detail
            if [ "${DEBUG:-false}" = true ]; then
                # shellcheck disable=SC2016
                smtp_out=$(INM_SMTP_HOST="$smtp_host" INM_SMTP_PORT="$smtp_port" php -r '
$host = getenv("INM_SMTP_HOST");
$port = (int) getenv("INM_SMTP_PORT");
$timeout = 3;
$errno = 0;
$errstr = "";
$fp = @fsockopen($host, $port, $errno, $errstr, $timeout);
if ($fp) { fclose($fp); echo "OK"; } else { echo "ERR:" . $errstr; }' 2>&1 || true)
            else
                # shellcheck disable=SC2016
                smtp_out=$(INM_SMTP_HOST="$smtp_host" INM_SMTP_PORT="$smtp_port" php -r '
$host = getenv("INM_SMTP_HOST");
$port = (int) getenv("INM_SMTP_PORT");
$timeout = 3;
$errno = 0;
$errstr = "";
$fp = @fsockopen($host, $port, $errno, $errstr, $timeout);
if ($fp) { fclose($fp); echo "OK"; } else { echo "ERR:" . $errstr; }' 2>/dev/null || true)
            fi
            if echo "$smtp_out" | grep -q "^OK"; then
                mail_emit OK "SMTP reachable: ${smtp_host}:${smtp_port}"
            else
                if [ "${DEBUG:-false}" = true ] && echo "$smtp_out" | grep -q "^ERR:"; then
                    smtp_detail="SMTP not reachable: ${smtp_host}:${smtp_port} (${smtp_out#ERR:})"
                else
                    smtp_detail="SMTP not reachable: ${smtp_host}:${smtp_port}"
                fi
                mail_emit WARN "$smtp_detail"
            fi
        else
            mail_emit INFO "Mail: not configured (MAIL_MAILER/MAIL_HOST unset)"
        fi
    fi
}

# ---------------------------------------------------------------------
# preflight_emit_php_cli()
# Emit PHP CLI settings for preflight output.
# Consumes: args: add_fn, out_var, emit_php, emit_ext; deps: phpinfo_probe_cli/php_thresholds.
# Computes: PHP CLI status lines and optional version output variable.
# Returns: 0 when phpinfo data available, 1 otherwise.
# ---------------------------------------------------------------------
preflight_emit_php_cli() {
    local add_fn="$1"
    local out_var="$2"
    local emit_php="${3:-true}"
    local emit_ext="${4:-false}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi

    local cli_php_out
    cli_php_out="$(phpinfo_probe_cli)" || true
    if [ -z "$cli_php_out" ]; then
        if [[ "$emit_php" == true ]]; then
            ${emit_fn:-log err} ERR "PHP" "php CLI not available"
        fi
        if [[ "$emit_ext" == true ]]; then
            ${emit_fn:-log err} ERR "EXT" "php CLI not available"
        fi
        return 1
    fi

    if [[ "$emit_php" == true ]]; then
        local phpv cli_ini cli_ini_scan_dir cli_ini_scanned cli_sapi cli_user_ini
        local mem inputvars opc max_exec max_input_time post_max upload_max realpath_cache display_errors error_reporting
        local cli_proc_open cli_exec cli_fpassthru cli_open_basedir cli_disable_functions
        while IFS='=' read -r key val; do
            case "$key" in
                PHP_VERSION) phpv="$val" ;;
                PHP_INI) cli_ini="$val" ;;
                PHP_INI_SCAN_DIR) cli_ini_scan_dir="$val" ;;
                PHP_INI_SCANNED) cli_ini_scanned="$val" ;;
                PHP_SAPI) cli_sapi="$val" ;;
                USER_INI) cli_user_ini="$val" ;;
                MEMORY_LIMIT) mem="$val" ;;
                MAX_INPUT_VARS) inputvars="$val" ;;
                OPCACHE) opc="$val" ;;
                MAX_EXEC) max_exec="$val" ;;
                MAX_INPUT_TIME) max_input_time="$val" ;;
                POST_MAX) post_max="$val" ;;
                UPLOAD_MAX) upload_max="$val" ;;
                REALPATH_CACHE_SIZE) realpath_cache="$val" ;;
                DISPLAY_ERRORS) display_errors="$val" ;;
                ERROR_REPORTING) error_reporting="$val" ;;
                PROC_OPEN) cli_proc_open="$val" ;;
                EXEC) cli_exec="$val" ;;
                FPASSTHRU) cli_fpassthru="$val" ;;
                OPEN_BASEDIR) cli_open_basedir="$val" ;;
                DISABLE_FUNCTIONS) cli_disable_functions="$val" ;;
            esac
        done <<< "$cli_php_out"
        ${emit_fn:-log info} OK "PHP" "CLI ${phpv:-unknown}"
        if printf '%s\n' "$phpv" "8.1.0" | sort -V | head -n1 | grep -qx "8.1.0"; then
            ${emit_fn:-log info} OK "PHP" ">= 8.1"
        else
            ${emit_fn:-log err} ERR "PHP" "Needs >= 8.1"
        fi
        [[ -n "$cli_sapi" ]] && ${emit_fn:-log info} INFO "PHP" "SAPI ${cli_sapi}"
        ${emit_fn:-log info} INFO "PHP" "php.ini ${cli_ini:-<none>}"
        [[ -n "$cli_ini_scan_dir" ]] && ${emit_fn:-log info} INFO "PHP" "ini scan dir ${cli_ini_scan_dir}"
        if [[ -n "$cli_ini_scanned" ]]; then
            local cli_ini_short
            cli_ini_short="$(shorten_ini_scanned "$cli_ini_scanned")"
            ${emit_fn:-log info} INFO "PHP" "ini scanned ${cli_ini_short}"
        fi
        local cli_user_ini_detail="${cli_user_ini:-<none>}"
        ${emit_fn:-log info} INFO "PHP" ".user.ini ${cli_user_ini_detail}"
        php_thresholds "$add_fn" "PHP" "$mem" "$inputvars" "$opc" "$max_exec" "$max_input_time" "$post_max" "$upload_max" "$realpath_cache" "$display_errors" "$error_reporting" "$cli_proc_open" "$cli_exec" "$cli_fpassthru" "$cli_open_basedir" "$cli_disable_functions"

        if [[ -n "$out_var" ]]; then
            # shellcheck disable=SC2178
            local -n out_ref="$out_var"
            # shellcheck disable=SC2034
            out_ref="$phpv"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------
# preflight_emit_php_ext()
# Emit PHP extension checks for preflight output.
# Consumes: args: add_fn; deps: php binary.
# Computes: extension availability lines.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_emit_php_ext() {
    local add_fn="$1"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi

    local exts=(bcmath ctype curl fileinfo gd gmp iconv imagick intl mbstring mysqli openssl pdo_mysql soap tokenizer xml zip)
    local ext
    for ext in "${exts[@]}"; do
        if php -m | grep -qi "^$ext$"; then
            ${emit_fn:-log info} OK "EXT" "$ext"
        else
            ${emit_fn:-log err} ERR "EXT" "$ext missing"
        fi
    done

    local saxon_loaded=""
    saxon_loaded="$(php -r 'echo extension_loaded("saxon") ? "1" : "0";' 2>/dev/null || true)"
    if [[ "$saxon_loaded" == "1" ]]; then
        ${emit_fn:-log info} OK "EXT" "saxon"
    else
        local saxon_path=""
        local ext_dir=""
        ext_dir="$(php -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
        if [[ -n "$ext_dir" && -f "${ext_dir%/}/saxon.so" ]]; then
            saxon_path="${ext_dir%/}/saxon.so"
        fi
        if [[ -z "$saxon_path" ]]; then
            saxon_path="$(find /usr/lib /usr/local/lib -type f -path "*/php/*/saxon.so" 2>/dev/null | head -n1 || true)"
        fi
        if [[ -n "$saxon_path" ]]; then
            ${emit_fn:-log info} INFO "EXT" "saxon present but not loaded: ${saxon_path}"
        else
            ${emit_fn:-log info} INFO "EXT" "saxon not installed (XSLT2). See: https://invoiceninja.github.io/en/self-host-installation/#lib-saxon"
        fi
    fi
}

# ---------------------------------------------------------------------
# preflight_fs_du_timeout()
# Compute a timeout for du size checks based on directory contents.
# Consumes: args: dir; env: INM_BASE_DIRECTORY, INM_BACKUP_DIRECTORY; tools: find.
# Computes: timeout in seconds.
# Returns: prints timeout.
# ---------------------------------------------------------------------
preflight_fs_du_timeout() {
    local dir="$1"
    local base=5
    local max=120
    local extra=0
    local normalized_dir="${dir%/}"
    local base_dir="${INM_BASE_DIRECTORY%/}"
    if [ -n "$base_dir" ] && [ -n "$normalized_dir" ] && [ "$normalized_dir" = "$base_dir" ]; then
        if [ -d "$dir" ]; then
            local count_base
            count_base=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$count_base" =~ ^[0-9]+$ ]]; then
                extra="$count_base"
            fi
        fi
    fi
    if [ -n "${INM_BACKUP_DIRECTORY:-}" ] && [ "$dir" = "$INM_BACKUP_DIRECTORY" ]; then
        if [ -d "$dir" ]; then
            local count
            count=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$count" =~ ^[0-9]+$ ]]; then
                extra="$count"
            fi
        fi
    fi
    local timeout=$((base + extra))
    if [ "$timeout" -gt "$max" ]; then
        timeout="$max"
    fi
    printf "%s" "$timeout"
}

# ---------------------------------------------------------------------
# preflight_check_cache_dir()
# Check cache directory writability and permissions.
# Consumes: args: path, label, key, state_var, detail_var, mode_var, world_var; deps: fs_user_can_write, _fs_get_mode.
# Computes: cache state, detail, and world-writable flag.
# Returns: 0 after evaluation.
# ---------------------------------------------------------------------
preflight_check_cache_dir() {
    local path="$1"
    local label="$2"
    local key="$3"
    local state_var="$4"
    local detail_var="$5"
    local mode_var="$6"
    local world_var="$7"
    local state="unset"
    local detail=""
    local mode=""
    local world=false

    if [[ -z "$path" ]]; then
        printf -v "$state_var" "%s" "$state"
        printf -v "$detail_var" "%s" "$detail"
        printf -v "$mode_var" "%s" "$mode"
        printf -v "$world_var" "%s" "$world"
        return 0
    fi

    if [[ ! -d "$path" ]]; then
        state="missing"
        detail="Missing: $path (Cache ${label}). Create it or set ${key} to a writable path."
        printf -v "$state_var" "%s" "$state"
        printf -v "$detail_var" "%s" "$detail"
        printf -v "$mode_var" "%s" "$mode"
        printf -v "$world_var" "%s" "$world"
        return 0
    fi

    local check_user="${INM_ENFORCED_USER:-}"
    if [ -z "$check_user" ]; then
        check_user="$(id -un 2>/dev/null || true)"
    fi
    if fs_user_can_write "$path" "$check_user" true; then
        state="ok"
        detail="Writable: $path (Cache ${label})"
        local size=""
        local du_rc=0
        size="$(fs_path_size_timeout "$path" 5)"
        du_rc=$?
        if [ "$du_rc" -eq 124 ]; then
            log debug "[FS] Cache ${label} size check timed out; skipping size."
        fi
        [[ -n "$size" ]] && detail+=" (Size: $size)"
        mode="$(_fs_get_mode "$path")"
        if [[ -n "$mode" ]]; then
            local other=$((mode % 10))
            if (( (other & 2) != 0 )); then
                world=true
            fi
        fi
    else
        state="fail"
        detail="Not writable: $path (Cache ${label})"
        if [ -n "${PREFLIGHT_ENFORCED_OWNER:-}" ]; then
            detail+=" (hint: chown -R ${PREFLIGHT_ENFORCED_OWNER} \"$path\" or use --override-enforced-user=true to adjust perms)"
        fi
        detail+=" or set ${key} to an accessible path."
    fi

    printf -v "$state_var" "%s" "$state"
    printf -v "$detail_var" "%s" "$detail"
    printf -v "$mode_var" "%s" "$mode"
    printf -v "$world_var" "%s" "$world"
}

# ---------------------------------------------------------------------
# preflight_warn_cache_world_writable()
# Emit a warning for world-writable cache directories.
# Consumes: args: label, path, mode; deps: add_result.
# Computes: warning message.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
preflight_warn_cache_world_writable() {
    local label="$1"
    local path="$2"
    local mode="$3"
    add_result WARN "FS" "Cache ${label} is world-writable: ${path} (mode=${mode}). Consider 775 with shared group or 750."
}

# ---------------------------------------------------------------------
# preflight_group_stats()
# Aggregate OK/WARN/ERR presence for a section.
# Consumes: args: group, any_var, warn_var, err_var; globals: PF_STATUS, PF_CHECK.
# Computes: booleans for section status.
# Returns: 0 after computing.
# ---------------------------------------------------------------------
preflight_group_stats() {
    local group="$1"
    local any_var="$2"
    local warn_var="$3"
    local err_var="$4"
    local any=false warn=false err=false
    local idx
    for idx in "${!PF_STATUS[@]}"; do
        if [[ "${PF_CHECK[$idx]}" == "$group" ]]; then
            any=true
            case "${PF_STATUS[$idx]}" in
                WARN) warn=true ;;
                ERR)  err=true ;;
            esac
        fi
    done
    printf -v "$any_var" "%s" "$any"
    printf -v "$warn_var" "%s" "$warn"
    printf -v "$err_var" "%s" "$err"
}

# ---------------------------------------------------------------------
# preflight_get_default_groups()
# Populate default group ordering for output/notifications.
# Consumes: args: out_ref (array).
# Computes: ordered tag list.
# Returns: 0 after assignment.
# ---------------------------------------------------------------------
preflight_get_default_groups() {
    local -n out_ref="$1"
    out_ref=("SYS" "FS" "PERM" "APP" "ENVCLI" "ENVAPP" "CLI" "CMD" "WEB" "PHP" "WEBPHP" "EXT" "NET" "MAIL" "DB" "CRON" "LOG" "SNAPPDF")
}

# ---------------------------------------------------------------------
# preflight_print_summary()
# Print the grouped preflight summary table.
# Consumes: args: format, groups_ref; globals: PF_STATUS/PF_CHECK/PF_DETAIL; deps: format_check_label/preflight_group_stats.
# Computes: summary output.
# Returns: 0 after printing.
# ---------------------------------------------------------------------
preflight_print_summary() {
    local format="$1"
    local -n groups_ref="$2"
    printf "\n"
    local idx g printed
    local green="${GREEN:-}"
    local yellow="${YELLOW:-}"
    local red="${RED:-}"
    local reset="${RESET:-}"
    local only_fail=false
    local print_ok_line=false

    if [[ "$format" == true || "$format" == "1" ]]; then
        format="compact"
    fi
    format="${format,,}"
    case "$format" in
        compact) only_fail=true; print_ok_line=true ;;
        failed) only_fail=true; print_ok_line=false ;;
        full) only_fail=false; print_ok_line=false ;;
        *) only_fail=false; print_ok_line=false ;;
    esac

    local max_check=7 max_status=6
    for idx in "${!PF_STATUS[@]}"; do
        local check_label
        check_label="$(format_check_label "${PF_CHECK[$idx]}")"
        local status="${PF_STATUS[$idx]}"
        (( ${#check_label}  > max_check )) && max_check=${#check_label}
        (( ${#status} > max_status )) && max_status=${#status}
    done

    for g in "${groups_ref[@]}"; do
        printed=false
        local group_has_any=false
        local group_has_warn=false
        local group_has_err=false
        preflight_group_stats "$g" group_has_any group_has_warn group_has_err
        if [[ "$only_fail" == true ]]; then
            if [[ "$group_has_any" != true ]]; then
                continue
            fi
            if [[ "$print_ok_line" != true && "$group_has_warn" != true && "$group_has_err" != true ]]; then
                continue
            fi
            local header
            header="$(format_check_label "$g")"
            printf "%b\n" "${BLUE}== $header ==${reset}"
            printf "%-*s | %-*s | %s\n" "$max_check" "Subject" "$max_status" "Status" "Detail"
            printf "%s\n" "$(printf '%*s' $((max_check+max_status+12)) '' | tr ' ' '-')"
            if [[ "$print_ok_line" == true && "$group_has_warn" != true && "$group_has_err" != true ]]; then
                local ok_subject
                ok_subject="$(format_check_label "$g")"
                printf -v check_field "%-*s" "$max_check" "$ok_subject"
                printf -v status_field "%-*s" "$max_status" "OK"
                status_field="${green}${status_field}${reset}"
                printf "%b\n\n" "$(printf "%s | %s | %s" "$check_field" "$status_field" "All checks OK")"
                continue
            fi
        fi
        for idx in "${!PF_STATUS[@]}"; do
            if [[ "${PF_CHECK[$idx]}" == "$g" ]]; then
                local raw_status="${PF_STATUS[$idx]}"
                if [[ "$only_fail" == true ]]; then
                    if [[ "$raw_status" != "WARN" && "$raw_status" != "ERR" ]]; then
                        continue
                    fi
                else
                    if [ "$printed" = false ]; then
                        local header
                        header="$(format_check_label "$g")"
                        printf "%b\n" "${BLUE}== $header ==${reset}"
                        printf "%-*s | %-*s | %s\n" "$max_check" "Subject" "$max_status" "Status" "Detail"
                        printf "%s\n" "$(printf '%*s' $((max_check+max_status+12)) '' | tr ' ' '-')"
                    fi
                fi
                printf -v status_field "%-*s" "$max_status" "$raw_status"
                case "$raw_status" in
                    OK)   status_field="${green}${status_field}${reset}";;
                    WARN) status_field="${yellow}${status_field}${reset}";;
                    ERR)  status_field="${red}${status_field}${reset}";;
                esac
                local row
                local check_label
                check_label="$(format_check_label "${PF_CHECK[$idx]}")"
                printf -v check_field "%-*s" "$max_check" "$check_label"
                row=$(printf "%s | %s | %s" "$check_field" "$status_field" "${PF_DETAIL[$idx]}")
                printf "%b\n" "$row"
                printed=true
            fi
        done
        if [ "$printed" = true ]; then
            printf "\n"
        fi
    done
}

# ---------------------------------------------------------------------
# preflight_build_notify_summary()
# Build a notification summary from preflight results.
# Consumes: args: format, groups_ref; env: INM_NOTIFY_HEARTBEAT_FORMAT/INM_NOTIFY_HEARTBEAT_LEVEL.
# Computes: summary string for emails/webhooks (compact|full|failed).
# Returns: prints summary to stdout.
# ---------------------------------------------------------------------
preflight_build_notify_summary() {
    local format="${1:-compact}"
    local -n groups_ref="$2"
    local notify_summary=""
    local idx g
    format="${format,,}"
    case "$format" in
        compact|full|failed) ;;
        *) format="compact" ;;
    esac

    if [[ "$format" == "compact" ]]; then
        for g in "${groups_ref[@]}"; do
            local group_has_any=false
            local group_has_warn=false
            local group_has_err=false
            preflight_group_stats "$g" group_has_any group_has_warn group_has_err
            if [[ "$group_has_any" != true ]]; then
                continue
            fi
            printf -v notify_summary '%s== %s ==\n' "$notify_summary" "$(format_check_label "$g")"
            if [[ "$group_has_warn" != true && "$group_has_err" != true ]]; then
                local ok_subject
                ok_subject="$(format_check_label "$g")"
                printf -v notify_summary '%s%s | OK | All checks OK\n\n' "$notify_summary" "$ok_subject"
                continue
            fi
            for idx in "${!PF_STATUS[@]}"; do
                if [[ "${PF_CHECK[$idx]}" == "$g" ]]; then
                    local status="${PF_STATUS[$idx]}"
                    if [[ "$status" != "WARN" && "$status" != "ERR" ]]; then
                        continue
                    fi
                    local check_label
                    check_label="$(format_check_label "${PF_CHECK[$idx]}")"
                    printf -v notify_summary '%s%s | %s | %s\n' "$notify_summary" "$check_label" "$status" "${PF_DETAIL[$idx]}"
                fi
            done
            printf -v notify_summary '%s\n' "$notify_summary"
        done
        notify_summary="${notify_summary%$'\n'}"
        printf "%s" "$notify_summary"
        return 0
    fi

    local detail_level=""
    if [[ "$format" == "full" ]]; then
        detail_level="OK"
    else
        detail_level="${INM_NOTIFY_HEARTBEAT_LEVEL:-ERR}"
        detail_level="${detail_level^^}"
    fi
    for g in "${groups_ref[@]}"; do
        local printed=false
        for idx in "${!PF_STATUS[@]}"; do
            if [[ "${PF_CHECK[$idx]}" == "$g" ]]; then
                local status="${PF_STATUS[$idx]}"
                if ! notify_level_allows "$status" "$detail_level"; then
                    continue
                fi
                if [ "$printed" = false ]; then
                    printf -v notify_summary '%s== %s ==\n' "$notify_summary" "$(format_check_label "$g")"
                    printed=true
                fi
                local check_label
                check_label="$(format_check_label "${PF_CHECK[$idx]}")"
                printf -v notify_summary '%s%s | %s | %s\n' "$notify_summary" "$check_label" "$status" "${PF_DETAIL[$idx]}"
            fi
        done
        if [ "$printed" = true ]; then
            printf -v notify_summary '%s\n' "$notify_summary"
        fi
    done
    notify_summary="${notify_summary%$'\n'}"
    printf "%s" "$notify_summary"
}

# ---------------------------------------------------------------------
# preflight_pick_probe_dir()
# Pick a writable existing directory for preflight probes (WRITE).
# Consumes: args: out_var, candidates...; deps: fs_user_can_write, expand_path_vars.
# Computes: first usable directory from candidates.
# Returns: 0 if found, 1 otherwise.
# ---------------------------------------------------------------------
preflight_pick_probe_dir() {
    local out_var="$1"
    shift || true
    local candidate resolved
    local current_user
    current_user="$(id -un 2>/dev/null || true)"
    for candidate in "$@"; do
        [ -z "$candidate" ] && continue
        resolved="$(expand_path_vars "$candidate")"
        [ -z "$resolved" ] && continue
        if [ -d "$resolved" ] && fs_user_can_write "$resolved" "$current_user" true; then
            printf -v "$out_var" "%s" "$resolved"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------
# preflight_ensure_dir()
# Ensure a directory exists for preflight probes (WRITE).
# Consumes: args: path, created_var; deps: mkdir.
# Computes: creates missing directory.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
preflight_ensure_dir() {
    local path="$1"
    local created_var="$2"
    [ -z "$path" ] && return 1
    if [ -d "$path" ]; then
        [[ -n "$created_var" ]] && printf -v "$created_var" "%s" "false"
        return 0
    fi
    local parent
    parent="$(dirname "$path")"
    if [ -z "$parent" ] || [ ! -d "$parent" ]; then
        return 1
    fi
    if mkdir -p "$path" 2>/dev/null; then
        [[ -n "$created_var" ]] && printf -v "$created_var" "%s" "true"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# preflight_track_created_dir()
# Record directories created by preflight for cleanup (WRITE).
# Consumes: args: dir; globals: PREFLIGHT_CREATED_DIRS.
# Computes: unique list of created directories.
# Returns: 0 after recording.
# ---------------------------------------------------------------------
preflight_track_created_dir() {
    local dir="$1"
    [ -z "$dir" ] && return 0
    local existing
    for existing in "${PREFLIGHT_CREATED_DIRS[@]}"; do
        [[ "$existing" == "$dir" ]] && return 0
    done
    PREFLIGHT_CREATED_DIRS+=("$dir")
}

# ---------------------------------------------------------------------
# preflight_cleanup_created_dirs()
# Remove temporary directories created during preflight (WRITE).
# Consumes: globals: PREFLIGHT_CREATED_DIRS; deps: log.
# Computes: directory cleanup (rmdir only).
# Returns: 0 after cleanup.
# ---------------------------------------------------------------------
preflight_cleanup_created_dirs() {
    local i dir
    for ((i=${#PREFLIGHT_CREATED_DIRS[@]}-1; i>=0; i--)); do
        dir="${PREFLIGHT_CREATED_DIRS[i]}"
        if rmdir "$dir" 2>/dev/null; then
            log debug "[PREFLIGHT] Removed temp dir: $dir"
        fi
    done
}

# ---------------------------------------------------------------------
# preflight_write_probe_file()
# Create a temp file for preflight probes (WRITE).
# Consumes: args: dir, prefix, suffix, out_var; deps: fs_user_can_write, mktemp, id.
# Computes: temp file path (caller must remove).
# Returns: 0 on success, 1 otherwise.
# ---------------------------------------------------------------------
preflight_write_probe_file() {
    local dir="$1"
    local prefix="${2:-preflight_probe}"
    local suffix="${3:-.tmp}"
    local out_var="$4"
    [ -z "$dir" ] && return 1
    [ -z "$out_var" ] && return 1
    if [ ! -d "$dir" ]; then
        return 1
    fi
    local current_user
    current_user="$(id -un 2>/dev/null || true)"
    if ! fs_user_can_write "$dir" "$current_user" true; then
        return 1
    fi
    local tmpl="${dir%/}/${prefix}_XXXX${suffix}"
    local tmp=""
    tmp="$(mktemp "$tmpl" 2>/dev/null || true)"
    [ -z "$tmp" ] && return 1
    printf -v "$out_var" "%s" "$tmp"
    return 0
}
