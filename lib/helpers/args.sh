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
            printf "[DEBUG][PNA] NAMED_ARGS[%s]=%s\n" "$k" "${_target[$k]}" >&2
        done
    fi
}
