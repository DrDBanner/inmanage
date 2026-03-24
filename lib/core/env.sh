#!/usr/bin/env bash

# ---------------------------------------------------------------------
# Core module: env.sh
# Scope: bootstrap environment defaults + core env vars (SCRIPT_*, PATH).
# Avoid: app/db/fs side effects; use helpers/services for that.
# Provides: setup_environment and core env helpers.
# ---------------------------------------------------------------------

# Prevent double sourcing
[[ -n ${__CORE_ENV_LOADED:-} ]] && return
__CORE_ENV_LOADED=1

format_helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/format.sh"
# shellcheck source=/dev/null
[ -f "$format_helper_path" ] && {
    source "$format_helper_path"
    __INM_LOADED_FILES="${__INM_LOADED_FILES:+$__INM_LOADED_FILES:}$format_helper_path"
}

# ---------------------------------------------------------------------
# setup_environment()
# Ensures PATH/TERM/Colors and defaults for env files.
# ---------------------------------------------------------------------
setup_environment() {
    # shellcheck disable=SC2034
    local original_path="$PATH"
    local clean_path="${PATH:-}"

    # Preserve the invoking user's home before any user switching.
    if [[ -z "${INM_ORIGINAL_HOME:-}" ]]; then
        local original_home="${HOME:-}"
        if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            local sudo_home=""
            if command -v getent >/dev/null 2>&1; then
                sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
            elif command -v pw >/dev/null 2>&1; then
                sudo_home="$(pw usershow "$SUDO_USER" 2>/dev/null | awk -F: '{print $9}')"
            fi
            if [[ -n "$sudo_home" && -d "$sudo_home" ]]; then
                original_home="$sudo_home"
            fi
        fi
        export INM_ORIGINAL_HOME="$original_home"
    fi

    local default_paths=(
        /usr/local/sbin
        /usr/local/bin
        /usr/sbin
        /usr/bin
        /sbin
        /bin
    )

    local os_id="${INM_OS_ID:-}"
    if [ -z "$os_id" ]; then
        os_id="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    fi
    local is_freebsd=0
    [ "$os_id" = "freebsd" ] && is_freebsd=1

    local extra_paths=(
        /usr/local/mysql/bin
    )
    # FreeBSD iports PHP versions: prefer newest installed.
    local mysql_iports_paths=()
    local mysql_iports_entries=()
    local mysql_dir=""
    local php_iports_paths=()
    local php_iports_entries=()
    local php_dir=""
    if [ "$is_freebsd" -eq 1 ] && [ -d /usr/iports ]; then
        extra_paths+=(/usr/iports/bin /usr/iports/sbin)
        for mysql_dir in /usr/iports/mysql*/bin; do
            [[ -d "$mysql_dir" ]] || continue
            local mysql_base
            mysql_base="$(basename "$(dirname "$mysql_dir")")"
            local mysql_num="${mysql_base#mysql}"
            if [[ "$mysql_num" =~ ^[0-9]+$ ]]; then
                mysql_iports_entries+=("${mysql_num}|${mysql_dir}")
            fi
        done
        if [ "${#mysql_iports_entries[@]}" -gt 0 ]; then
            local sorted_mysql=()
            mapfile -t sorted_mysql < <(printf '%s\n' "${mysql_iports_entries[@]}" | sort -rn)
            mysql_iports_paths+=("${sorted_mysql[0]#*|}")
        fi
        for php_dir in /usr/iports/php*/bin; do
            [[ -d "$php_dir" ]] || continue
            local php_base
            php_base="$(basename "$(dirname "$php_dir")")"
            local php_num="${php_base#php}"
            if [[ "$php_num" =~ ^[0-9]+$ ]]; then
                php_iports_entries+=("${php_num}|${php_dir}")
            fi
        done
        if [ "${#php_iports_entries[@]}" -gt 0 ]; then
            local sorted_php=()
            mapfile -t sorted_php < <(printf '%s\n' "${php_iports_entries[@]}" | sort -rn)
            php_iports_paths+=("${sorted_php[0]#*|}")
        fi
    fi

    for p in "${default_paths[@]}" "${extra_paths[@]}" "${mysql_iports_paths[@]}" "${php_iports_paths[@]}"; do
        [[ -d "$p" ]] && case ":$clean_path:" in
            *":$p:"*) : ;;    # already present → skip
            *) clean_path="${clean_path:+$clean_path:}$p" ;;
        esac
    done

    export PATH="$clean_path"
    export TERM="${TERM:-dumb}"

    # Colors via helper
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        setup_colors
    else
        GREEN=''
        RED=''
        CYAN=''
        # shellcheck disable=SC2034
        YELLOW=''
        BLUE=''
        WHITE=''
        MAGENTA=''
        # shellcheck disable=SC2034
        GRAY=''
        BOLD=''
        RESET=''
    fi
    # Backward-compat alias
    if [[ -z "${NC+x}" ]]; then
        # shellcheck disable=SC2034
        NC="${RESET}"
    fi
    
    [[ -n "$BASH_VERSION" ]] || {
        log err "This script requires Bash."
        local config_root="${INM_CONFIG_ROOT:-.inmanage}"
        local self_env_basename="${INM_SELF_ENV_BASENAME:-.env.inmanage}"
        local self_env_file="${INM_SELF_ENV_FILE:-${config_root%/}/${self_env_basename}}"
        local enforced_user=""
        local current_user=""

        if [ -f "$self_env_file" ]; then
            local line val
            line="$(grep -E '^INM_EXEC_USER=' "$self_env_file" | tail -n1)"
            if [ -n "$line" ]; then
                val="${line#*=}"
                val="${val%%#*}"
                val="$(printf "%s" "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                val="${val%\"}"
                val="${val#\"}"
                enforced_user="$val"
            fi
        fi

        current_user="$(id -un 2>/dev/null || true)"
        if [ -n "$enforced_user" ] && [ "$current_user" != "$enforced_user" ]; then
            log_hint "ENV" "Try: sudo -u ${enforced_user} bash ./inmanage.sh"
        else
            log_hint "ENV" "Try: bash ./inmanage.sh"
        fi

        exit 1
    }

    # Allow relocating config roots/basenames without hard-coding .inmanage
    INM_CONFIG_ROOT="${INM_CONFIG_ROOT:-.inmanage}"
    INM_SELF_ENV_BASENAME="${INM_SELF_ENV_BASENAME:-.env.inmanage}"
    INM_PROVISION_ENV_BASENAME="${INM_PROVISION_ENV_BASENAME:-.env.provision}"
    INM_DEFAULT_SELF_ENV_FILE="${INM_CONFIG_ROOT%/}/${INM_SELF_ENV_BASENAME}"
    INM_SELF_ENV_FILE="${INM_SELF_ENV_FILE:-$INM_DEFAULT_SELF_ENV_FILE}"
    # shellcheck disable=SC2034
    INM_PROVISION_ENV_FILE="${INM_PROVISION_ENV_FILE:-${INM_CONFIG_ROOT%/}/${INM_PROVISION_ENV_BASENAME}}"
    # shellcheck disable=SC2034
    CURL_AUTH_FLAG=()

    # Script identity (used in logs/help)
    SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
    SCRIPT_PATH="${SCRIPT_PATH:-$0}"

    if [[ "${DEBUG:-false}" == true && -n "${__INM_LOADED_FILES:-}" ]]; then
        log debug "[ENV] Loaded files: ${__INM_LOADED_FILES}"
    fi
}

# ---------------------------------------------------------------------
# safe_clear()
# ---------------------------------------------------------------------
safe_clear() {
    if [[ -t 1 && "$TERM" != "dumb" && "${DEBUG:-false}" != true && -z "${INM_CHILD_REEXEC:-}" ]]; then
        clear
    fi
}

# ---------------------------------------------------------------------
# log()
# ---------------------------------------------------------------------
log_compact_message() {
    local msg="$*"
    local rest="$msg"
    while [[ "$rest" =~ ^\[[^][]+\][[:space:]]*(.*)$ ]]; do
        rest="${BASH_REMATCH[1]}"
    done
    if [[ -n "$rest" ]]; then
        printf "%s" "$rest"
    else
        printf "%s" "$msg"
    fi
}

log_redact_emails() {
    local msg="$*"
    if [[ "$msg" != *"@"* ]]; then
        printf "%s" "$msg"
        return 0
    fi
    if command -v sed >/dev/null 2>&1; then
        printf "%s" "$msg" | sed -E 's/([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/\1@redacted/g'
    else
        printf "%s" "$msg"
    fi
}

log() {
    local type="$1"; shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local compact=false
    case "${INM_COMPACT_OUTPUT,,}" in
        1|true|yes|on) compact=true ;;
    esac
    local prefix=""
    if [[ "$compact" != true ]]; then
        prefix="${timestamp} "
    fi
    local msg="$*"
    if [[ "$compact" == true ]]; then
        msg="$(log_compact_message "$msg")"
    fi
    msg="$(log_redact_emails "$msg")"
    local history_level=""
    if [[ -n "${INM_HISTORY_LOG_VERBOSE:-}" && -n "${INM_OPS_LOG_ACTION:-}" ]]; then
        if [[ "${INM_HISTORY_LOG_VERBOSE}" == "${INM_OPS_LOG_ACTION}" ]]; then
            case "$type" in
                debug) history_level="DEBUG" ;;
                info) history_level="INFO" ;;
                note|docs|bold) history_level="INFO" ;;
                ok) history_level="OK" ;;
                warn|important) history_level="WARN" ;;
                err) history_level="ERR" ;;
                *) history_level="" ;;
            esac
            if [[ -n "$history_level" ]]; then
                if declare -F history_log_append >/dev/null 2>&1; then
                    history_log_append "${INM_OPS_LOG_ACTION}:log" "$history_level" "$*"
                fi
            fi
        fi
    fi

    case "$type" in
        debug)
            if [ "$DEBUG" = true ]; then
                if [[ "$compact" == true ]]; then
                    printf "${CYAN}%s${RESET}\n" "$msg" >&2
                else
                    printf "${CYAN}%s[DEBUG] %s${RESET}\n" "$prefix" "$msg" >&2
                fi
            fi
            ;;
        info)
            if [[ "$compact" == true ]]; then
                printf "${WHITE}%s${RESET}\n" "$msg" >&2
            else
                printf "${WHITE}%s[INFO] %s${RESET}\n" "$prefix" "$msg" >&2
            fi
            ;;
        note)
            local count=$#
            local i=1
            for arg in "$@"; do
                if [ "$i" -lt "$count" ]; then
                    printf "${WHITE}%s %s${RESET}" $'' "$arg" >&2
                else
                    printf "${WHITE}%s %s${RESET}\n" $'' "$arg" >&2
                fi
                ((i++))
            done
            ;;
        docs)
            printf "${GREEN}%s %s${RESET}\n" "$*" >&2
            ;;
        ok)
            if [[ "$compact" == true ]]; then
                printf "${GREEN}%s${RESET}\n" "$msg" >&2
            else
                printf "${GREEN}%s[OK] %s${RESET}\n" "$prefix" "$msg" >&2
            fi
            ;;
        warn)
            if [[ "$compact" == true ]]; then
                printf "${MAGENTA}%s${RESET}\n" "$msg" >&2
            else
                printf "${MAGENTA}%s[WARN] %s${RESET}\n" "$prefix" "$msg" >&2
            fi
            ;;
        important)
            if [[ "$compact" == true ]]; then
                printf "${MAGENTA}%s${RESET}\n" "$msg" >&2
            else
                printf "${MAGENTA}%s[IMPORTANT] %s${RESET}\n" "$prefix" "$msg" >&2
            fi
            ;;
        err)
            local log_user=""
            log_user="$(id -un 2>/dev/null || echo unknown)"
            if [[ "$compact" == true ]]; then
                printf "${RED}%s (user: %s)${RESET}\n" "$msg" "$log_user" >&2
            else
                printf "${RED}%s[ERR] %s (user: %s)${RESET}\n" "$prefix" "$msg" "$log_user" >&2
            fi
            ;;
        bold)
            if [[ "$compact" == true ]]; then
                printf "${BOLD}%s${RESET}\n" "$msg" >&2
            else
                printf "${BOLD}%s[BOLD] %s${RESET}\n" "$prefix" "$msg" >&2
            fi
            ;;
        *)
            echo "$*" >&2
            ;;
    esac
}

# ---------------------------------------------------------------------
# trace helpers
# ---------------------------------------------------------------------
trace_can_guard() {
    if [[ "${DEBUG_LEVEL:-0}" -lt 2 ]]; then
        return 1
    fi
    case "${INM_TRACE_SENSITIVE_GUARD_ENABLE,,}" in
        0|false|no|off) return 1 ;;
    esac
    return 0
}

trace_suspend() {
    if [[ $- != *x* ]]; then
        return 1
    fi
    local depth="${INM_TRACE_SUSPEND_DEPTH:-0}"
    depth=$((depth + 1))
    INM_TRACE_SUSPEND_DEPTH="$depth"
    if [[ "$depth" -eq 1 ]]; then
        set +o xtrace
    fi
    return 0
}

trace_resume() {
    local depth="${INM_TRACE_SUSPEND_DEPTH:-0}"
    if [[ "$depth" -le 0 ]]; then
        return 0
    fi
    depth=$((depth - 1))
    if [[ "$depth" -eq 0 ]]; then
        unset INM_TRACE_SUSPEND_DEPTH
        set -o xtrace
    else
        INM_TRACE_SUSPEND_DEPTH="$depth"
    fi
    return 0
}

trace_suspend_if_sensitive_key() {
    local key="$1"
    if ! trace_can_guard; then
        return 1
    fi
    if declare -F _env_key_is_sensitive >/dev/null 2>&1 && _env_key_is_sensitive "$key"; then
        trace_suspend
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# require_function()
# Ensure a function is defined; log and return non-zero if missing.
# Consumes: args: fn, context(optional); deps: log.
# Computes: missing function list (optional via require_functions).
# Returns: 0 if present, 1 if missing.
# ---------------------------------------------------------------------
require_function() {
    local fn="$1"
    local context="${2:-BOOT}"
    if declare -F "$fn" >/dev/null 2>&1; then
        return 0
    fi
    log err "[${context}] Required function missing: ${fn}"
    return 1
}

# ---------------------------------------------------------------------
# require_functions()
# Ensure a list of functions are defined; logs once and returns non-zero if any missing.
# Consumes: args: fn...; deps: require_function/log.
# Computes: missing function list.
# Returns: 0 if all present, 1 if any missing.
# ---------------------------------------------------------------------
require_functions() {
    local context="BOOT"
    local -a missing=()
    local fn
    for fn in "$@"; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            missing+=("$fn")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        log err "[${context}] Missing required functions: ${missing[*]}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# log_hint()
# ---------------------------------------------------------------------
log_hint() {
    local scope="$1"; shift
    if [[ -n "$scope" ]]; then
        log info "[$scope] $*"
    else
        log info "$*"
    fi
}

# ---------------------------------------------------------------------
# print_logo()
# ---------------------------------------------------------------------
print_logo() {
    # shellcheck disable=SC2059
    {
        printf "${BLUE}"
        printf "    _____   __                                       __\n"
        printf "   /  _/ | / /___ ___  ____ _____  ____ _____ ____  / /\n"
        printf "   / //  |/ / __ \`__ \\/ __ \`/ __ \\/ __ \`/ __ \`/ _ \\/ / \n"
        printf " _/ // /|  / / / / / / /_/ / / / / /_/ / /_/ /  __/_/  \n"
        printf "/___/_/ |_/_/ /_/ /_/\\__,_/_/ /_/\\__,_/\\__, /\\___(_)   \n"
        printf "                                      /____/           ${RESET}\n"
        printf "${BLUE}${BOLD}CLI FOR INVOICE NINJA! by DrDBanner${RESET}\n\n"
        printf "\n\n"
    }
}
