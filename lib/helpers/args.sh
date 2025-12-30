#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__ARGS_HELPER_LOADED:-} ]] && return
__ARGS_HELPER_LOADED=1

# ---------------------------------------------------------------------
# parse_named_args()
#
# Parses --key=value pairs into an associative array for easy access.
# Converts dashes to underscores in keys.
#
# Globals used:
#   DEBUG (for verbose output)
# ---------------------------------------------------------------------
parse_named_args() {
    declare -n _target="$1"
    shift
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
#
# Returns the first matching key value from a local assoc array (if provided)
# and then from global NAMED_ARGS. Keys can be passed with dashes or underscores.
# If a key exists with an empty value, that empty value is returned.
#
# Usage:
#   args_get ARGS "default" key1 key2 key3
#   args_get - "default" key1 key2
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
# ---------------------------------------------------------------------
args_is_true() {
    local value="${1:-}"
    case "${value,,}" in
        1|true|yes|y|on) return 0 ;;
    esac
    return 1
}
