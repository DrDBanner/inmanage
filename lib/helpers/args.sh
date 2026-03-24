#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__ARGS_HELPER_LOADED:-} ]] && return
__ARGS_HELPER_LOADED=1

# ---------------------------------------------------------------------
# parse_named_args()
# Parse --key=value pairs into an assoc array.
# Consumes: args: target array name, argv; env: DEBUG (optional); deps: log.
# Computes: normalized keys and values.
# Returns: 0 always.
# ---------------------------------------------------------------------
parse_named_args() {
    declare -n _target="$1"
    shift
    local arg key value
    for arg in "$@"; do
        if [[ "$arg" == --* ]]; then
            key="${arg%%=*}"
            key="${key#--}"
            key="${key//-/_}"    # Convert dashes to underscores
            if [[ "$arg" == *"="* ]]; then
                value="${arg#*=}"
            else
                value="true"
            fi
            _target["$key"]="$value"
        fi
    done

    if [[ "$DEBUG" = true ]]; then
        for k in "${!_target[@]}"; do
            if command -v log >/dev/null 2>&1; then
                log debug "[PNA] NAMED_ARGS[$k]=${_target[$k]}"
            else
                printf "[DEBUG] [PNA] NAMED_ARGS[%s]=%s\n" "$k" "${_target[$k]}" >&2
            fi
        done
    fi
}

# ---------------------------------------------------------------------
# args_get()
# Return the first matching value from local array or NAMED_ARGS.
# Consumes: args: array name, default, keys; env: NAMED_ARGS.
# Computes: key lookup with dash/underscore normalization.
# Returns: value on stdout (default if none).
# ---------------------------------------------------------------------
args_get() {
    local arr_name="$1"
    shift
    local default="$1"
    shift
    local key=""
    local has_local=false
    local has_global=false
    local -n arr_ref

    if [[ -n "$arr_name" && "$arr_name" != "-" ]] && declare -p "$arr_name" >/dev/null 2>&1; then
        has_local=true
        declare -n arr_ref="$arr_name"
    fi
    if declare -p NAMED_ARGS >/dev/null 2>&1; then
        has_global=true
    fi

    for key in "$@"; do
        key="${key//-/_}"
        if [[ "$has_local" == true && ${arr_ref[$key]+_} ]]; then
            printf "%s" "${arr_ref[$key]}"
            return 0
        fi
        if [[ "$has_global" == true && ${NAMED_ARGS[$key]+_} ]]; then
            printf "%s" "${NAMED_ARGS[$key]}"
            return 0
        fi
    done
    printf "%s" "$default"
}

# ---------------------------------------------------------------------
# args_is_true()
# Truthy check for CLI-style values.
# Consumes: args: value.
# Computes: boolean test.
# Returns: 0 if true, 1 if false.
# ---------------------------------------------------------------------
args_is_true() {
    local value="${1:-}"
    case "${value,,}" in
        1|true|yes|y|on) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------
# args_named_snapshot()
# Copy the global NAMED_ARGS associative array into a caller-provided map.
# Consumes: args: target assoc array name; env: NAMED_ARGS.
# Computes: snapshot of current named args.
# Returns: 0 always.
# ---------------------------------------------------------------------
args_named_snapshot() {
    local target_name="$1"
    [[ -z "$target_name" ]] && return 0

    declare -n _snapshot="$target_name"
    _snapshot=()

    if ! declare -p NAMED_ARGS >/dev/null 2>&1; then
        return 0
    fi

    local key
    for key in "${!NAMED_ARGS[@]}"; do
        _snapshot["$key"]="${NAMED_ARGS[$key]}"
    done
}

# ---------------------------------------------------------------------
# args_named_restore()
# Replace the global NAMED_ARGS associative array from a snapshot map.
# Consumes: args: source assoc array name.
# Computes: restored NAMED_ARGS contents.
# Returns: 0 always.
# ---------------------------------------------------------------------
args_named_restore() {
    local source_name="$1"
    declare -g -A NAMED_ARGS=()

    [[ -z "$source_name" ]] && return 0

    declare -n _snapshot="$source_name"
    local key
    for key in "${!_snapshot[@]}"; do
        NAMED_ARGS["$key"]="${_snapshot[$key]}"
    done
}
