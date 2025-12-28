#!/usr/bin/env bash

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
    local clean_path=""

    # Preserve original home for defaults before any user switching
    export INM_ORIGINAL_HOME="${INM_ORIGINAL_HOME:-${HOME:-}}"

    local default_paths=(
        /usr/local/sbin
        /usr/local/bin
        /usr/sbin
        /usr/bin
        /sbin
        /bin
    )

    local extra_paths=(
        /usr/iports/bin
        /usr/iports/sbin
        /usr/iports/mysql84/bin
        /usr/local/mysql/bin
    )

    IFS=':' read -ra path_parts <<< "$PATH"
    for dir in "${path_parts[@]}"; do
        [[ -d "$dir" ]] && case ":$clean_path:" in
            *":$dir:"*) : ;;  # already present → skip
            *) clean_path="${clean_path:+$clean_path:}$dir" ;;
        esac
    done

    for p in "${default_paths[@]}" "${extra_paths[@]}"; do
        [[ -d "$p" ]] && case ":$clean_path:" in
            *":$p:"*) : ;;    # already present → skip
            *) clean_path="$clean_path:$p" ;;
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
            enforced_user="$(grep -E '^INM_ENFORCED_USER=' "$self_env_file" | tail -n1 | cut -d= -f2- | tr -d '"')"
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
    CURL_AUTH_FLAG=""

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
log() {
    local type="$1"; shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    case "$type" in
        debug)
            if [ "$DEBUG" = true ]; then
                printf "${CYAN}%s [DEBUG] %s${RESET}\n" "$timestamp" "$*" >&2
            fi
            ;;
        info)
            printf "${WHITE}%s [INFO] %s${RESET}\n" "$timestamp" "$*" >&2
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
            printf "${GREEN}%s [OK] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        warn)
            printf "${MAGENTA}%s [WARN] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        important)
            printf "${MAGENTA}%s [IMPORTANT] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        err)
            local log_user=""
            log_user="$(id -un 2>/dev/null || echo unknown)"
            printf "${RED}%s [ERR] %s (user: %s)${RESET}\n" "$timestamp" "$*" "$log_user" >&2
            ;;
        bold)
            printf "${BOLD}%s [BOLD] %s${RESET}\n" "$timestamp" "$*" >&2
            ;;
        *)
            echo "$*" >&2
            ;;
    esac
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
