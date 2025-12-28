#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__USER_HELPER_LOADED:-} ]] && return
__USER_HELPER_LOADED=1

# ---------------------------------------------------------------------
# enforce_user_switch()
#
# Switches to target user if --user is provided; optional switchback.
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

        exec sudo -u "${args[user]}" env INM_ORIGINAL_HOME="$original_home" bash "$memyselfasscript" "${providedargs[@]}"
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
# True when a user switch will happen and we're still pre-switch.
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
