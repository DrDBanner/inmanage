#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HELPER_SPINNER_LOADED:-} ]] && return
__HELPER_SPINNER_LOADED=1

spinner_can_run() {
    [[ "${INM_SPINNER:-on}" =~ ^(0|off|false|no)$ ]] && return 1
    [[ "${DEBUG:-false}" == true ]] && return 1
    if declare -p NAMED_ARGS >/dev/null 2>&1; then
        [[ "${NAMED_ARGS[debug]:-false}" == true ]] && return 1
    fi
    [[ -w /dev/tty ]] || return 1
    return 0
}

spinner_start() {
    local msg="${1:-}"
    local style="${2:-${INM_SPINNER_STYLE:-spinner}}"
    local clear_flag="${3:-${INM_SPINNER_CLEAR:-}}"
    spinner_stop
    spinner_can_run || return 0
    if [[ "$clear_flag" =~ ^(1|true|yes|on|clear)$ ]] && declare -F safe_clear >/dev/null 2>&1; then
        safe_clear
    fi

    SPINNER_TTY="/dev/tty"
    SPINNER_MSG="$msg"
    SPINNER_STYLE="$style"

    (
        local i=0
        local frames='|/-\'
        local dots=( "." ".." "..." )
        while true; do
            case "$SPINNER_STYLE" in
                dots)
                    local d="${dots[$((i % 3))]}"
                    printf "\r%s%s" "$SPINNER_MSG" "$d" >"$SPINNER_TTY"
                    ;;
                *)
                    local f="${frames:$((i % 4)):1}"
                    if [ -n "$SPINNER_MSG" ]; then
                        printf "\r%s %s" "$f" "$SPINNER_MSG" >"$SPINNER_TTY"
                    else
                        printf "\r%s" "$f" >"$SPINNER_TTY"
                    fi
                    ;;
            esac
            i=$((i + 1))
            sleep 0.12
        done
    ) &

    SPINNER_PID=$!
}

spinner_stop() {
    local final="${1:-}"
    if [ -n "${SPINNER_PID:-}" ] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
    fi
    if [ -n "${SPINNER_TTY:-}" ] && [ -w "$SPINNER_TTY" ]; then
        if [ -n "$final" ]; then
            printf "\r\033[K%s\n" "$final" >"$SPINNER_TTY"
        else
            printf "\r\033[K" >"$SPINNER_TTY"
        fi
    fi
    SPINNER_PID=""
    SPINNER_TTY=""
    SPINNER_MSG=""
    SPINNER_STYLE=""
}

spinner_run() {
    local msg="${1:-}"
    shift
    spinner_start "$msg"
    "$@"
    local rc=$?
    spinner_stop
    return $rc
}
