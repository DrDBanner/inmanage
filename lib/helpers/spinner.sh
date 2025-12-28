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
        # shellcheck disable=SC1003
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

run_with_watchdog() {
    local timeout="$1"
    local heartbeat="$2"
    local msg="$3"
    shift 3

    local errexit_set=false
    [[ $- == *e* ]] && errexit_set=true
    set +e
    local interrupted=false
    local cmd_pid=""
    local old_int old_term
    old_int="$(trap -p INT)"
    old_term="$(trap -p TERM)"
    trap 'interrupted=true; if [ -n "$cmd_pid" ]; then kill "$cmd_pid" 2>/dev/null || true; fi; spinner_stop' INT TERM

    "$@" &
    cmd_pid=$!
    local start now last_beat
    start="$(date +%s)"
    last_beat="$start"
    local timed_out=false

    while kill -0 "$cmd_pid" 2>/dev/null; do
        sleep 1
        now="$(date +%s)"
        if [ "$interrupted" = true ]; then
            break
        fi
        if [[ "$heartbeat" =~ ^[0-9]+$ ]] && [ "$heartbeat" -gt 0 ]; then
            if [ $((now - last_beat)) -ge "$heartbeat" ]; then
                if declare -F log >/dev/null 2>&1; then
                    log info "[WAIT] ${msg:-Working}..."
                else
                    printf "%s [INFO] [WAIT] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${msg:-Working}" >&2
                fi
                last_beat="$now"
            fi
        fi
        if [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ]; then
            if [ $((now - start)) -ge "$timeout" ]; then
                timed_out=true
                kill "$cmd_pid" 2>/dev/null || true
                sleep 2
                kill -9 "$cmd_pid" 2>/dev/null || true
                break
            fi
        fi
    done

    local rc=0
    if [ "$interrupted" = true ]; then
        wait "$cmd_pid" 2>/dev/null || true
        rc=130
    elif [ "$timed_out" = true ]; then
        wait "$cmd_pid" 2>/dev/null || true
        if declare -F log >/dev/null 2>&1; then
            log err "[TIMEOUT] ${msg:-Command} exceeded ${timeout}s; aborted."
        else
            printf "%s [ERR] [TIMEOUT] %s exceeded %ss; aborted.\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${msg:-Command}" "$timeout" >&2
        fi
        rc=124
    else
        wait "$cmd_pid"
        rc=$?
    fi

    if [ -n "$old_int" ]; then
        eval "$old_int"
    else
        trap - INT
    fi
    if [ -n "$old_term" ]; then
        eval "$old_term"
    else
        trap - TERM
    fi
    $errexit_set && set -e
    return $rc
}

spinner_run() {
    local msg="${1:-}"
    shift
    spinner_start "$msg"
    local timeout="${INM_SPINNER_TIMEOUT:-0}"
    local heartbeat="${INM_SPINNER_HEARTBEAT:-20}"
    local rc=0
    if [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || [[ "$heartbeat" =~ ^[0-9]+$ ]] && [ "$heartbeat" -gt 0 ]; then
        run_with_watchdog "$timeout" "$heartbeat" "$msg" "$@"
        rc=$?
    else
        "$@"
        rc=$?
    fi
    spinner_stop
    return $rc
}
