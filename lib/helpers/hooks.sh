#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HOOKS_HELPER_LOADED:-} ]] && return
__HOOKS_HELPER_LOADED=1

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
# run_hook()
# Execute pre/post hooks with env or file-based configuration.
# Pre-* hooks abort on failure. Post-* hooks warn unless INM_HOOK_STRICT=true.
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
        if [[ "$fail_on_error" == true ]]; then
            log err "[HOOK] Hook failed ($event) with exit code $rc."
            return "$rc"
        fi
        log warn "[HOOK] Hook failed ($event) with exit code $rc; continuing."
        return 0
    fi

    log ok "[HOOK] Completed: $event"
    return 0
}
