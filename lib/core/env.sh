#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__CORE_ENV_LOADED:-} ]] && return
__CORE_ENV_LOADED=1

format_helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/format.sh"
[ -f "$format_helper_path" ] && source "$format_helper_path"

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
    setup_colors
    # Backward-compat alias
    NC="${RESET}"
    
    [[ -n "$BASH_VERSION" ]] || {
        log err "This script requires Bash."

        if [ -f ".inmanage/.env.inmanage" ]; then
            user=$(grep '^INM_ENFORCED_USER=' .inmanage/.env.inmanage | cut -d= -f2 | tr -d '"')
            log info "Try: sudo -u ${user:-{your-user}} bash ./inmanage.sh"
        else
            log info "Try: sudo -u {your-user} bash ./inmanage.sh"
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
            printf "${RED}%s [ERR] %s${RESET}\n" "$timestamp" "$*" >&2
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
        printf "${BLUE}${BOLD}THE CLI FOR INVOICE NINJA!${RESET}\n\n"
        printf "\n\n"
    }
}
