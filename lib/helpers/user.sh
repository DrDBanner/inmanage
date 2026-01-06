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
        local fix_perms="${args[fix_permissions]:-${args[fix-permissions]:-false}}"
        if [[ "$current_user" == "root" && "$fix_perms" == "true" ]]; then
            log info "[ENV] Hint: use --override-enforced-user to keep root for --fix-permissions."
        fi

        local -a env_args=(INM_ORIGINAL_HOME="$original_home")
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
