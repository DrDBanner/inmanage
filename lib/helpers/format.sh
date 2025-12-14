#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__FORMAT_HELPER_LOADED:-} ]] && return
__FORMAT_HELPER_LOADED=1

# ---------------------------------------------------------------------
# setup_colors()
# Centralized color definitions for CLI output.
# ---------------------------------------------------------------------
setup_colors() {
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
