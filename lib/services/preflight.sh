#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_PREFLIGHT_LOADED:-} ]] && return
__SERVICE_PREFLIGHT_LOADED=1

preflight_helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd)"
if [[ -f "${preflight_helpers_dir}/preflight_utils.sh" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${preflight_helpers_dir}/preflight_utils.sh"
else
    return 1
fi

# ---------------------------------------------------------------------
# run_preflight()
# Run health checks for INmanage/Invoice Ninja.
# Consumes: args: --checks/--exclude/--fast/--skip-github/...; env: INM_*; helpers: preflight_utils, gh/git/fs/http.
# Computes: section results + aggregate status; optional notify test.
# Returns: 0 on completion; non-zero only on hard aborts.
# ---------------------------------------------------------------------
run_preflight() {
    local errexit_set=false
    if [[ $- == *e* ]]; then
        errexit_set=true
        set +e
    fi
    local -A ARGS=()
    parse_named_args ARGS "$@"
    local pf_label="${INM_PREFLIGHT_LABEL:-PREFLIGHT}"
    local enforced_owner=""
    local enforced_user="${ENFORCED_USER:-${INM_ENFORCED_USER:-}}"
    local enforced_group="${INM_ENFORCED_GROUP:-}"
    local fast="${ARGS[fast]:-false}"
    local skip_snappdf="${ARGS[skip_snappdf]:-false}"
    local skip_github="${ARGS[skip_github]:-false}"
    local force_raw
    force_raw="$(args_get ARGS "false" force)"
    local update_due=true
    if declare -F update_notice_should_check >/dev/null 2>&1; then
        if ! update_notice_should_check "$force_raw"; then
            update_due=false
        fi
    fi
    local cli_config_present=false
    local current_user=""
    local invoked_user=""
    local can_enforce=false
    preflight_compute_context "$enforced_user" "$enforced_group" \
        enforced_owner can_enforce current_user cli_config_present
    invoked_user="${INM_INVOKED_BY:-$current_user}"
    # Resolve env file path early so probes/readers behave consistently.
    if [ -n "${INM_ENV_FILE:-}" ]; then
        local env_file_resolved
        env_file_resolved="$(expand_path_vars "$INM_ENV_FILE")"
        if [ -n "$env_file_resolved" ]; then
            INM_ENV_FILE="$env_file_resolved"
        fi
    fi
    # shellcheck disable=SC2034
    INM_PREFLIGHT_CAN_ENFORCE="$can_enforce"
    # shellcheck disable=SC2034
    PREFLIGHT_ENFORCED_OWNER="$enforced_owner"

    # Track probe-created directories to keep preflight side-effects temporary.
    # shellcheck disable=SC2034
    PREFLIGHT_CREATED_DIRS=()
    trap preflight_cleanup_created_dirs RETURN

    # Optional check filter (CSV of tags, e.g., CLI,SYS,FS,DB,WEB,PHP,EXT,NET,MAIL,APP,CRON,SNAPPDF,PERM).
    local preflight_valid_tags="CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,MAIL,DB,APP,CRON,LOG,SNAPPDF,PERM"
    local -A allowed_args=(
        [checks]=1
        [check]=1
        [exclude]=1
        [exclude_checks]=1
        [exclude-checks]=1
        [notify_test]=1
        [notify-test]=1
        [notify_heartbeat]=1
        [notify-heartbeat]=1
        [fix_permissions]=1
        [format]=1
        [debug]=1
        [debuglevel]=1
        [debug_level]=1
        [dry_run]=1
        [force]=1
        [override_enforced_user]=1
        [user]=1
        [no_cli_clear]=1
        [fast]=1
        [skip_snappdf]=1
        [skip_github]=1
    )
    local -A unknown_args=()
    local arg_key
    for arg_key in "${!ARGS[@]}"; do
        if [[ -z "${allowed_args[$arg_key]:-}" ]]; then
            unknown_args["$arg_key"]=1
        fi
    done
    if declare -p NAMED_ARGS >/dev/null 2>&1; then
        for arg_key in "${!NAMED_ARGS[@]}"; do
            if [[ -z "${allowed_args[$arg_key]:-}" ]]; then
                unknown_args["$arg_key"]=1
            fi
        done
    fi
    if (( ${#unknown_args[@]} > 0 )); then
        local -a bad_args=()
        for arg_key in "${!unknown_args[@]}"; do
            bad_args+=("--${arg_key//_/-}")
        done
        log err "[${pf_label}] Unknown arguments: ${bad_args[*]}"
        log info "[${pf_label}] Allowed flags: --checks=TAG1,TAG2 --check=TAG1,TAG2 --exclude=TAG1,TAG2 --fix-permissions --notify-test --notify-heartbeat --format=compact|full|failed --debug --debuglevel=1|2 --dry-run --override-enforced-user --no-cli-clear --fast --skip-snappdf --skip-github"
        $errexit_set && set -e
        return 1
    fi

    # Prefer globally parsed NAMED_ARGS to survive re-exec user switches.
    local fix_permissions_raw
    fix_permissions_raw="$(args_get ARGS "false" fix_permissions)"
    local fix_permissions=false
    checks_filter="$(args_get ARGS "" checks check)"
    exclude_filter="$(args_get ARGS "" exclude exclude_checks)"
    local notify_test_raw
    notify_test_raw="$(args_get ARGS "false" notify_test)"
    local notify_test=false
    local notify_heartbeat_raw
    notify_heartbeat_raw="$(args_get ARGS "false" notify_heartbeat)"
    local notify_heartbeat=false
    local notify_format_raw
    notify_format_raw="$(args_get ARGS "" format)"
    local notify_format=""
    local output_format=""
    args_is_true "$fix_permissions_raw" && fix_permissions=true
    args_is_true "$notify_test_raw" && notify_test=true
    args_is_true "$notify_heartbeat_raw" && notify_heartbeat=true
    if [[ -n "$notify_format_raw" ]]; then
        output_format="$notify_format_raw"
    else
        output_format="full"
    fi
    output_format="${output_format,,}"
    case "$output_format" in
        compact|full|failed) ;;
        *) output_format="full" ;;
    esac
    if [[ -n "$notify_format_raw" ]]; then
        notify_format="$notify_format_raw"
    else
        notify_format="${INM_NOTIFY_HEARTBEAT_FORMAT:-}"
    fi
    notify_format="${notify_format,,}"
    if [[ -z "$notify_format" ]]; then
        local legacy_detail="${INM_NOTIFY_HEARTBEAT_DETAIL_LEVEL:-auto}"
        legacy_detail="${legacy_detail^^}"
        case "$legacy_detail" in
            OK|INFO|ALL) notify_format="full" ;;
            WARN|ERR) notify_format="failed" ;;
            AUTO|"") notify_format="failed" ;;
            *) notify_format="compact" ;;
        esac
    fi
    case "$notify_format" in
        compact|full|failed) ;;
        *) notify_format="compact" ;;
    esac
    # Heartbeat runs can narrow/expand checks using stored include/exclude lists.
    if [[ "$notify_heartbeat" == true ]]; then
        local hb_include="${INM_NOTIFY_HEARTBEAT_CHECK_INCLUDE:-}"
        local hb_include_legacy="${INM_NOTIFY_HEARTBEAT_INCLUDE:-}"
        if [[ -z "$hb_include" && -n "$hb_include_legacy" ]]; then
            hb_include="$hb_include_legacy"
        fi
        if [[ -n "$hb_include" && -z "$checks_filter" ]]; then
            checks_filter="$hb_include"
        fi
        local hb_exclude="${INM_NOTIFY_HEARTBEAT_CHECK_EXCLUDE:-}"
        local hb_exclude_legacy="${INM_NOTIFY_HEARTBEAT_EXCLUDE:-}"
        if [[ -n "$hb_exclude_legacy" ]]; then
            if [[ -z "$hb_exclude" ]]; then
                hb_exclude="$hb_exclude_legacy"
            else
                hb_exclude="${hb_exclude},${hb_exclude_legacy}"
            fi
        fi
        if [[ -n "$hb_exclude" ]]; then
            if [[ -z "$exclude_filter" ]]; then
                exclude_filter="$hb_exclude"
            else
                exclude_filter="${exclude_filter},${hb_exclude}"
            fi
        fi
    fi
    if [[ -n "${INM_HEALTH_CHECK_INCLUDE:-}" && -z "$checks_filter" ]]; then
        checks_filter="${INM_HEALTH_CHECK_INCLUDE}"
    fi
    if [[ -n "${INM_HEALTH_CHECK_EXCLUDE:-}" ]]; then
        if [[ -z "$exclude_filter" ]]; then
            exclude_filter="${INM_HEALTH_CHECK_EXCLUDE}"
        else
            exclude_filter="${exclude_filter},${INM_HEALTH_CHECK_EXCLUDE}"
        fi
    fi
    if [ "$fix_permissions" = true ] && [ -z "$checks_filter" ]; then
        checks_filter="APP,PERM"
    fi
    declare -gA PF_ALLOW=()
    # shellcheck disable=SC2034
    declare -gA PF_DENY=()
    declare -ga unknown_checks=()
    if [[ -n "$checks_filter" ]]; then
        preflight_apply_filter "$checks_filter" "allow"
        if [[ ${#PF_ALLOW[@]} -eq 0 ]]; then
            log err "[${pf_label}] No valid check tags in --checks=$checks_filter"
            log info "[${pf_label}] Valid tags: $preflight_valid_tags"
            $errexit_set && set -e
            return 1
        fi
        log debug "[${pf_label}] Checks filter active: $checks_filter"
    fi
    if [[ -n "$exclude_filter" ]]; then
        preflight_apply_filter "$exclude_filter" "deny"
        log debug "[${pf_label}] Exclude filter active: $exclude_filter"
    fi
    if [[ ${#unknown_checks[@]} -gt 0 ]]; then
        log err "[${pf_label}] Unknown check tags: ${unknown_checks[*]}"
        log info "[${pf_label}] Valid tags: $preflight_valid_tags"
        $errexit_set && set -e
        return 1
    fi
    local -a conflicts=()
    local tag
    for tag in "${!PF_ALLOW[@]}"; do
        if [[ -n "${PF_DENY[$tag]:-}" ]]; then
            conflicts+=("$tag")
            unset 'PF_ALLOW[$tag]'
        fi
    done
    if (( ${#conflicts[@]} > 0 )); then
        log warn "[${pf_label}] Conflicting health check filters (include+exclude): ${conflicts[*]} (exclude wins)"
    fi

    # Results collector (drives summary and notifications).
    declare -ga PF_STATUS=()
    declare -ga PF_CHECK=()
    declare -ga PF_DETAIL=()

    ok=0
    warn=0
    err=0
    local phpv=""
    log info "[${pf_label}] Starting system checks"

    # Mandatory CLI command check (fail-fast message).
    if should_run "CMD"; then
        if ! preflight_require_commands "$pf_label" "preflight"; then
            $errexit_set && set -e
            return 1
        fi
    fi

    spinner_start "Running ${pf_label} checks..."

    if should_run "CLI"; then
        # ---- CLI self info ----
        preflight_emit_cli_info add_result "$fast" "$skip_github" "$update_due"
    fi
    if should_run "SYS"; then
        # ---- System details ----
        sys_emit_preflight add_result
    fi

    # Hydrate APP_URL from app .env if missing (used by WEBPHP/NET probes).
    if should_run "NET" || should_run "WEBPHP"; then
        preflight_hydrate_app_url
    fi

    if should_run "WEB"; then
        # ---- Webserver detection ----
        web_emit_preflight add_result "${INM_INSTALLATION_PATH%/}"
    fi

    # ---- Command availability ----
    if should_run "CMD"; then
        preflight_emit_commands add_result "preflight"
    fi

    if should_run "APP"; then
        # ---- App sanity & permissions ----
        local app_cfg_hint=""
        if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "${INM_SELF_ENV_FILE:-}" ]; then
            app_cfg_hint="CLI config: ${INM_SELF_ENV_FILE}"
        fi
        if [ -n "${INM_ENV_FILE:-}" ] && [ -f "${INM_ENV_FILE:-}" ]; then
            if [ -n "$app_cfg_hint" ]; then
                app_cfg_hint+=" | App env: ${INM_ENV_FILE}"
            else
                app_cfg_hint="App env: ${INM_ENV_FILE}"
            fi
        fi
        if [ -n "${INM_INSTALLATION_PATH:-}" ] && [ -d "${INM_INSTALLATION_PATH%/}" ]; then
            local app_dir="${INM_INSTALLATION_PATH%/}"
            app_emit_preflight add_result "$app_dir" "$app_cfg_hint" "$fast" "$skip_github" "$update_due"
            if [ -n "$enforced_user" ]; then
                fs_emit_permissions_preflight add_result "$enforced_user" "$fix_permissions" "$app_dir"
            fi
        else
            add_result WARN "APP" "App directory missing or unset: ${INM_INSTALLATION_PATH:-<unset>}"
            if [ -n "$app_cfg_hint" ]; then
                add_result WARN "APP" "Config found (${app_cfg_hint}) but app directory is missing. Fix: move app to ${INM_INSTALLATION_PATH%/} or run 'inm core install --provision'. Help: 'inm core install --help' or docs."
            fi
        fi
    fi

    if should_run "PHP" || should_run "EXT" || should_run "WEBPHP"; then
        # ---- PHP version / ini ----
        local phpv=""
        local php_cli_ok=false
        local run_php="false"
        local run_ext="false"
        if should_run "PHP"; then
            run_php="true"
        fi
        if should_run "EXT"; then
            run_ext="true"
        fi
        if preflight_emit_php_cli add_result phpv "$run_php" "$run_ext"; then
            php_cli_ok=true
        fi

        if [[ "$php_cli_ok" == true && "$run_ext" == "true" ]]; then
            preflight_emit_php_ext add_result
        fi
    fi

    # ---- Web PHP check ----
    if should_run "WEBPHP"; then
        webphp_emit_preflight "$phpv" add_result "$enforced_owner"
    fi

    if should_run "FS"; then
        # ---- Filesystem perms ----
        preflight_emit_filesystem add_result "$cli_config_present" "$enforced_owner"
    fi

    # ---- ENV (CLI / APP) ----
    if should_run "ENVCLI"; then
        preflight_emit_env_cli add_result
    fi

    if should_run "ENVAPP"; then
        preflight_emit_env_app add_result
    fi

    if should_run "DB" || should_run "APP"; then
        db_emit_preflight add_result "DB" "APP"
    fi

    if should_run "CRON"; then
        cron_emit_preflight add_result "$enforced_user" "$current_user" "$invoked_user"
    fi

    if should_run "LOG"; then
        ops_log_emit_preflight add_result "$fix_permissions" "$can_enforce"
    fi

    if should_run "SNAPPDF"; then
        snappdf_emit_preflight add_result "$fast" "$skip_snappdf"
    fi

    if should_run "NET"; then
        preflight_emit_network add_result "$fast" "$skip_github"
    fi

    if should_run "MAIL"; then
        preflight_emit_mail add_result
    fi

    spinner_stop

    # shellcheck disable=SC2034
    local -a groups=()
    preflight_get_default_groups groups
    preflight_print_summary "$output_format" groups

    if [[ "${DEBUG:-false}" == true ]]; then
        local idx
        for idx in "${!PF_STATUS[@]}"; do
            if [[ "${PF_STATUS[$idx]}" == "WARN" || "${PF_STATUS[$idx]}" == "ERR" ]]; then
                log debug "[HEALTH] ${PF_CHECK[$idx]} ${PF_STATUS[$idx]} ${PF_DETAIL[$idx]}"
            fi
        done
    fi

    log info "[${pf_label}] Completed: OK=$ok WARN=$warn ERR=$err"
    local aggregate_status="OK"
    if [ "$err" -gt 0 ]; then
        aggregate_status="ERR"
    elif [ "$warn" -gt 0 ]; then
        aggregate_status="WARN"
    fi
    log info "[${pf_label}] Aggregate status: ${aggregate_status}"

    if [[ "$notify_heartbeat" == true || "$notify_test" == true ]]; then
        local notify_summary=""
        notify_summary="$(preflight_build_notify_summary "$notify_format" groups)"
        if [[ "$notify_heartbeat" == true ]]; then
            notify_emit_heartbeat "$aggregate_status" "$ok" "$warn" "$err" "$notify_summary"
        fi
        if [[ "$notify_test" == true ]]; then
            notify_send_test "$aggregate_status" "$ok" "$warn" "$err" "$notify_summary"
        fi
    fi

    if [ "$err" -gt 0 ]; then
        $errexit_set && set -e
        return 1
    fi
    $errexit_set && set -e
    return 0
}
