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

    local use_color=false
    if [[ -t 2 && "${NO_COLOR:-}" != "1" ]]; then
        use_color=true
    fi

    local prompt_raw prompt_rendered
    if [[ "$use_color" == true ]]; then
        prompt_raw="${GREEN}\n${text}\n${RESET}${GRAY}[${default}]${RESET} > "
    else
        prompt_raw=$'\n'"${text}"$'\n'"[${default}] > "
    fi
    printf -v prompt_rendered "%b" "$prompt_raw"

    local read_opts=(-r -t "$timeout" -p "$prompt_rendered")
    [[ "$silent" == "true" ]] && read_opts+=(-s)

    # shellcheck disable=SC2162
    if read "${read_opts[@]}" input; then
        echo "${input:-$default}"
    else
        local read_rc=$?
        echo   # newline
        if [[ "$read_rc" -eq 142 ]]; then
            log err "[PROMPT] Timeout after ${timeout}s – no input received"
        else
            log err "[PROMPT] Input aborted"
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------
# prompt_confirm()
# Yes/No prompt with default, optional silent, timeout. Returns 0 on yes.
# ---------------------------------------------------------------------
prompt_confirm() {
    local key="$1"
    local default="${2:-no}"
    local text="${3:-Proceed?}"
    local silent="${4:-false}"
    local timeout="${5:-60}"

    local reply
    reply="$(prompt_var "$key" "$default" "$text" "$silent" "$timeout")" || return 1
    [[ "$reply" =~ ^([yY][eE][sS]|[yY])$ ]]
}

# ---------------------------------------------------------------------
# prompt_secret_keep_current()
# Keeps current value when input is empty; hides input.
# ---------------------------------------------------------------------
prompt_secret_keep_current() {
    local prompt="$1"
    local current="$2"
    local timeout="${3:-60}"
    local input=""
    if [[ ! -t 0 ]]; then
        log err "[PROMPT] No TTY available for secret input."
        return 1
    fi
    printf "\n%s\n" "$prompt" >&2
    printf "[leave blank to keep current] > " >&2
    # shellcheck disable=SC2162
    if ! read -r -s -t "$timeout" input; then
        echo >&2
        log err "[PROMPT] Input aborted"
        return 1
    fi
    echo >&2
    if [[ -z "$input" ]]; then
        printf "%s" "$current"
    else
        printf "%s" "$input"
    fi
}
