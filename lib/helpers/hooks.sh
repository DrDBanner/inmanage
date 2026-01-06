#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HOOKS_HELPER_LOADED:-} ]] && return
__HOOKS_HELPER_LOADED=1

# ---------------------------------------------------------------------
# resolve_hooks_dir()
# Resolve the hooks directory path (absolute).
# Consumes: env: INM_HOOKS_DIR, INM_CONFIG_ROOT, INM_BASE_DIRECTORY; cwd.
# Computes: absolute hooks directory.
# Returns: prints hooks directory to stdout.
# ---------------------------------------------------------------------
resolve_hooks_dir() {
    local hooks_dir="${INM_HOOKS_DIR:-${INM_CONFIG_ROOT%/}/hooks}"
    if [[ "$hooks_dir" != /* ]]; then
        if [[ -n "${INM_BASE_DIRECTORY:-}" ]]; then
            hooks_dir="${INM_BASE_DIRECTORY%/}/${hooks_dir#/}"
        else
            hooks_dir="$(pwd)/${hooks_dir#/}"
        fi
    fi
    printf "%s" "$hooks_dir"
}

# ---------------------------------------------------------------------
# hook_notify_bool()
# Normalize a truthy/falsey value for hook notifications.
# Consumes: args: value; deps: notify_bool (optional).
# Computes: boolean decision.
# Returns: 0 for true, 1 for false.
# ---------------------------------------------------------------------
hook_notify_bool() {
    local val="${1:-}"
    notify_bool "$val"
    return $?
}

# ---------------------------------------------------------------------
# hook_notify_enabled()
# Check whether hook notifications are enabled.
# Consumes: env: INM_NOTIFY_HOOKS_ENABLED.
# Computes: boolean decision.
# Returns: 0 if enabled, 1 otherwise.
# ---------------------------------------------------------------------
hook_notify_enabled() {
    hook_notify_bool "${INM_NOTIFY_HOOKS_ENABLED:-true}"
}

# ---------------------------------------------------------------------
# hook_notify_success_enabled()
# Check whether hook success notifications are enabled.
# Consumes: env: INM_NOTIFY_HOOKS_SUCCESS.
# Computes: boolean decision.
# Returns: 0 if enabled, 1 otherwise.
# ---------------------------------------------------------------------
hook_notify_success_enabled() {
    hook_notify_bool "${INM_NOTIFY_HOOKS_SUCCESS:-false}"
}

# ---------------------------------------------------------------------
# hook_notify_failure_enabled()
# Check whether hook failure notifications are enabled.
# Consumes: env: INM_NOTIFY_HOOKS_FAILURE.
# Computes: boolean decision.
# Returns: 0 if enabled, 1 otherwise.
# ---------------------------------------------------------------------
hook_notify_failure_enabled() {
    hook_notify_bool "${INM_NOTIFY_HOOKS_FAILURE:-true}"
}

# ---------------------------------------------------------------------
# hook_notify_emit()
# Emit a hook notification via the notify subsystem.
# Consumes: args: level, title, details; deps: notify_emit_event.
# Computes: notification dispatch when enabled.
# Returns: 0 when no action or on success.
# ---------------------------------------------------------------------
hook_notify_emit() {
    local level="$1"
    local title="$2"
    local details="${3:-}"
    if ! hook_notify_enabled; then
        return 0
    fi
    notify_emit_event "$level" "$title" "$details"
}

# ---------------------------------------------------------------------
# run_hook()
# Execute a hook script for the given event.
# Consumes: args: event; env: INM_HOOK_* / INM_HOOKS_DIR / INM_HOOK_STRICT / DRY_RUN.
# Computes: resolves hook path and executes it.
# Returns: hook exit code (pre-* aborts), 0 on non-strict post-* failure.
# ---------------------------------------------------------------------
run_hook() {
    local event="$1"
    if [[ -z "$event" ]]; then
        log err "[HOOK] Missing hook event name."
        return 1
    fi

    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping hook: $event"
        return 0
    fi

    local event_key="${event^^}"
    event_key="${event_key//-/_}"
    local env_var="INM_HOOK_${event_key}"
    local hook_path="${!env_var:-}"
    local from_env=false

    if [[ -n "$hook_path" ]]; then
        from_env=true
    else
        local hooks_dir
        hooks_dir="$(resolve_hooks_dir)"
        hook_path="${hooks_dir%/}/${event}"
    fi

    if [[ ! -e "$hook_path" ]]; then
        if [[ "$from_env" == true ]]; then
            log err "[HOOK] Configured hook not found: $hook_path"
            return 1
        fi
        log debug "[HOOK] No hook configured for $event."
        return 0
    fi
    if [[ -d "$hook_path" ]]; then
        log err "[HOOK] Hook path is a directory: $hook_path"
        return 1
    fi
    if [[ ! -r "$hook_path" ]]; then
        log err "[HOOK] Hook not readable: $hook_path"
        return 1
    fi

    export INM_HOOK_EVENT="$event"
    export INM_HOOK_STAGE="${event%%-*}"
    export INM_HOOK_NAME="${event#*-}"
    export INM_HOOK_SCRIPT="$hook_path"

    log info "[HOOK] Running $event: $hook_path"

    local rc=0
    if [[ -x "$hook_path" ]]; then
        "$hook_path"
        rc=$?
    else
        bash "$hook_path"
        rc=$?
    fi

    if [[ "$rc" -ne 0 ]]; then
        local strict="${INM_HOOK_STRICT:-false}"
        local fail_on_error=false
        if [[ "$event" == pre-* ]]; then
            fail_on_error=true
        fi
        if [[ "$strict" == "true" ]]; then
            fail_on_error=true
        fi
        if hook_notify_failure_enabled; then
            local fail_level="WARN"
            if [[ "$fail_on_error" == true ]]; then
                fail_level="ERR"
            fi
            local fail_details
            fail_details=$(printf "Hook: %s\nExit code: %s" "$hook_path" "$rc")
            hook_notify_emit "$fail_level" "Hook failed: ${event}" "$fail_details"
        fi
        if [[ "$fail_on_error" == true ]]; then
            log err "[HOOK] Hook failed ($event) with exit code $rc."
            return "$rc"
        fi
        log warn "[HOOK] Hook failed ($event) with exit code $rc; continuing."
        return 0
    fi

    if hook_notify_success_enabled; then
        local ok_details
        ok_details=$(printf "Hook: %s" "$hook_path")
        hook_notify_emit "OK" "Hook succeeded: ${event}" "$ok_details"
    fi
    log ok "[HOOK] Completed: $event"
    return 0
}
