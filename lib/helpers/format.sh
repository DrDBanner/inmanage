#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__FORMAT_HELPER_LOADED:-} ]] && return
__FORMAT_HELPER_LOADED=1

# ---------------------------------------------------------------------
# setup_colors()
# Initialize ANSI color variables for CLI output.
# Consumes: tty state (stdout).
# Computes: color variables.
# Returns: 0 always.
# ---------------------------------------------------------------------
setup_colors() {
    # shellcheck disable=SC2034
    if [[ -t 1 ]]; then
        GREEN='\033[0;32m'
        RED='\033[0;31m'
        CYAN='\033[0;36m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        WHITE='\033[1;37m'
        MAGENTA='\033[0;35m'
        GRAY='\033[0;90m'
        BOLD='\033[1m'
        RESET='\033[0m'
    else
        GREEN=''; RED=''; CYAN=''; YELLOW=''; BLUE=''; WHITE=''; MAGENTA=''; GRAY=''; BOLD=''; RESET=''
    fi
}

# ---------------------------------------------------------------------
# mem_to_mb()
# Convert memory string to MB.
# Consumes: args: val.
# Computes: integer MB from K/M/G or numeric.
# Returns: MB on stdout (empty if invalid).
# ---------------------------------------------------------------------
mem_to_mb() {
    local val="$1"
    if [[ "$val" =~ ^-?[0-9]+$ ]]; then
        echo "$val"
        return
    fi
    if [[ "$val" =~ ^([0-9]+)([KkMmGg])$ ]]; then
        local mem_val="${BASH_REMATCH[1]}"
        local mem_unit="${BASH_REMATCH[2]}"
        case "$mem_unit" in
            K|k) echo $((mem_val / 1024));;
            M|m) echo "$mem_val";;
            G|g) echo $((mem_val * 1024));;
        esac
        return
    fi
    echo ""
}

# ---------------------------------------------------------------------
# escape_regex()
# Escape a string for safe regex use.
# Consumes: args: string; tools: sed.
# Computes: escaped string.
# Returns: escaped string on stdout.
# ---------------------------------------------------------------------
escape_regex() {
    printf '%s' "$1" | sed -E 's/[][\\.^$*+?(){}|]/\\&/g'
}
