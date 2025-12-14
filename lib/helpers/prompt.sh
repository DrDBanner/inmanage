#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__PROMPT_HELPER_LOADED:-} ]] && return
__PROMPT_HELPER_LOADED=1

# ---------------------------------------------------------------------
# prompt_var()
#
# Reads input with default, optional silent mode, timeout, and custom text.
# Shared helper so all modules can prompt consistently.
#
# Globals used:
#   GREEN, GRAY, RESET, prompt_texts (from config), log()
# ---------------------------------------------------------------------
prompt_var() {
    # Parameters:
    #   $1 = var (variable name)
    #   $2 = default (default value)
    #   $3 = text (optional: prompt text, defaults to prompt_texts[$var])
    #   $4 = silent (optional: if true, input is hidden, defaults to false)
    #   $5 = timeout (optional: timeout in seconds, defaults to 60)
    #
    # Usage example:
    #   username=$(prompt_var "username" "admin" "Enter username:")
    #   password=$(prompt_var "db_pass" "" "Enter DB password:" true 30)

    local var="$1"
    local default="$2"
    local text="${3:-${prompt_texts[$var]}}"
    local silent="${4:-false}"
    local timeout="${5:-60}"
    local input=""

    local prompt="${GREEN}\n${text}\n${RESET}${GRAY}[$default]${RESET} > "

    local read_opts=(-r -t "$timeout" -p "$prompt")
    [[ "$silent" == "true" ]] && read_opts+=(-s)

    # shellcheck disable=SC2162
    if read "${read_opts[@]}" input; then
        echo "${input:-$default}"
    else
        echo   # newline
        log err "[PROMPT] Timeout after ${timeout}s – no input received"
        return 1
    fi
}
