#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__USER_HELPER_LOADED:-} ]] && return
__USER_HELPER_LOADED=1

# ---------------------------------------------------------------------
# enforce_user_switch()
# Re-exec the script as the target user when requested.
# Consumes: args: user, switchback, override_enforced_user, fix_permissions; env: INM_OVERRIDE_ENFORCED_USER, DRY_RUN.
# Computes: re-exec decision and user switch command.
# Returns: 0 when no switch is needed; otherwise execs the script.
# ---------------------------------------------------------------------
enforce_user_switch() {
    local -A args=()
    parse_named_args args "$@"

    local providedargs=("$@")

    # Allow bypassing enforced user for this invocation
    if [[ "${args[override_enforced_user]:-}" == "true" || "${INM_OVERRIDE_ENFORCED_USER:-}" == "true" ]]; then
        log info "[ENV] override_enforced_user set; skipping enforced user switch."
        return 0
    fi

    local current_user
    current_user="$(whoami)"

    if [[ "${DRY_RUN:-false}" == true && -n "${args[user]:-}" && "$current_user" != "${args[user]}" ]]; then
        log info "[ENV] Dry-run: skipping user switch to '${args[user]}' (staying as $current_user)."
        return 0
    fi

    if [ -z "${args[user]}" ]; then
        log debug "[ENV] No --user specified, staying as $current_user."
    elif [ "$current_user" = "${args[user]}" ]; then
        log debug "[ENV] Already running as ${args[user]}, no switch required."
    fi

    if [ -n "${args[user]}" ] && [ "$current_user" != "${args[user]}" ]; then
        unset __INTERNAL_SWITCHED_FROM_USER
        # shellcheck disable=SC2155
        export __INTERNAL_SWITCHED_FROM_USER="$current_user"
        export INM_CHILD_REEXEC=1
        local original_home="${INM_ORIGINAL_HOME:-$HOME}"

        local memyselfasscript
        memyselfasscript="$(resolve_script_path "$0")"

        log debug "[ENV] Switching to user '${args[user]}'."
        log debug "[ENV] If you don't want to switch users, put your current user into the INM_ENFORCED_USER variable in your config file."
        log info "[ENV] Hint: use --override-enforced-user to skip enforced user switching for this run."
        local fix_perms="${args[fix_permissions]:-${args[fix-permissions]:-false}}"
        if [[ "$current_user" == "root" && "$fix_perms" == "true" ]]; then
            log info "[ENV] Hint: use --override-enforced-user to keep root for --fix-permissions."
        fi

        local invoked_by="${INM_INVOKED_BY:-$current_user}"
        local -a env_args=(INM_ORIGINAL_HOME="$original_home" INM_INVOKED_BY="$invoked_by")
        local invoked_snapshot=""
        local invoked_snapshot_file=""
        local snapshot_ok=false
        if command -v crontab >/dev/null 2>&1; then
            if [[ "$invoked_by" == "$current_user" ]]; then
                invoked_snapshot="$(crontab -l 2>/dev/null || true)"
                snapshot_ok=true
            elif [[ $EUID -eq 0 ]]; then
                invoked_snapshot="$(crontab -l -u "$invoked_by" 2>/dev/null || true)"
                snapshot_ok=true
            elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
                invoked_snapshot="$(sudo -n crontab -l -u "$invoked_by" 2>/dev/null || true)"
                snapshot_ok=true
            fi
        fi
        local invoked_home=""
        if [[ "$invoked_by" == "$current_user" ]]; then
            invoked_home="${HOME:-}"
        elif command -v getent >/dev/null 2>&1; then
            invoked_home="$(getent passwd "$invoked_by" 2>/dev/null | cut -d: -f6)"
        fi
        if [[ -n "$invoked_home" ]]; then
            local home_cronfile="${invoked_home%/}/cronfile"
            if [[ -r "$home_cronfile" ]]; then
                invoked_snapshot+=$'\n'"$(cat "$home_cronfile" 2>/dev/null || true)"
                snapshot_ok=true
            fi
        fi
        invoked_snapshot="$(printf "%s\n" "$invoked_snapshot" | grep -E 'inmanage|inm|invoiceninja|artisan schedule:run|notify-heartbeat|core backup' || true)"
        if [[ "$snapshot_ok" == true ]]; then
            if command -v mktemp >/dev/null 2>&1; then
                invoked_snapshot_file="$(mktemp "/tmp/inmanage.cron.${invoked_by}.XXXXXX" 2>/dev/null || true)"
            fi
            if [[ -z "$invoked_snapshot_file" ]]; then
                invoked_snapshot_file="/tmp/inmanage.cron.${invoked_by}.$$"
            fi
            if printf "%s\n" "$invoked_snapshot" > "$invoked_snapshot_file" 2>/dev/null; then
                chmod 0644 "$invoked_snapshot_file" 2>/dev/null || true
                if [[ $EUID -eq 0 && -n "${args[user]:-}" ]]; then
                    chown "${args[user]}" "$invoked_snapshot_file" 2>/dev/null || true
                fi
                env_args+=(INM_INVOKED_CRON_SNAPSHOT="$invoked_snapshot_file")
            fi
        fi
        if [[ -n "${INM_INSTALL_TIMESTAMP:-}" ]]; then
            env_args+=(INM_INSTALL_TIMESTAMP="$INM_INSTALL_TIMESTAMP")
        fi
        if [[ -n "${INM_INSTALL_ROLLBACK_DIR:-}" ]]; then
            env_args+=(INM_INSTALL_ROLLBACK_DIR="$INM_INSTALL_ROLLBACK_DIR")
        fi
        if [[ -n "${INM_PROVISION_ENV_FILE:-}" ]]; then
            env_args+=(INM_PROVISION_ENV_FILE="$INM_PROVISION_ENV_FILE")
        fi
        if [[ -n "${INM_SELF_ENV_FILE:-}" ]]; then
            env_args+=(INM_SELF_ENV_FILE="$INM_SELF_ENV_FILE")
        fi

        exec sudo -u "${args[user]}" env "${env_args[@]}" bash "$memyselfasscript" "${providedargs[@]}"
    fi

    if [ -n "${args[switchback]}" ] && [ -n "$__INTERNAL_SWITCHED_FROM_USER" ]; then
        log info "[ENV] Switching back to user '$__INTERNAL_SWITCHED_FROM_USER'."

        local memyselfasscript
        memyselfasscript="$(resolve_script_path "$0")"

        local old_from="$__INTERNAL_SWITCHED_FROM_USER"
        unset __INTERNAL_SWITCHED_FROM_USER

        exec sudo -u "$old_from" -- bash "$memyselfasscript" "${providedargs[@]}"
    fi
}

# ---------------------------------------------------------------------
# should_suppress_pre_switch_logs()
# Decide whether to suppress logs before a user switch.
# Consumes: env: INM_CHILD_REEXEC, INM_OVERRIDE_ENFORCED_USER, INM_ENFORCED_USER, DRY_RUN; global: NAMED_ARGS.
# Computes: whether current run is pre-switch.
# Returns: 0 to suppress logs, 1 otherwise.
# ---------------------------------------------------------------------
should_suppress_pre_switch_logs() {
    if [[ -n "${INM_CHILD_REEXEC:-}" ]]; then
        return 1
    fi
    if [[ "${NAMED_ARGS[override_enforced_user]:-}" == "true" || "${INM_OVERRIDE_ENFORCED_USER:-}" == "true" ]]; then
        return 1
    fi
    local target_user="${INM_ENFORCED_USER:-}"
    if [[ -z "$target_user" ]]; then
        return 1
    fi
    local current_user
    current_user="$(whoami 2>/dev/null || true)"
    if [[ "$current_user" != "$target_user" && "${DRY_RUN:-false}" != true ]]; then
        return 0
    fi
    return 1
}
