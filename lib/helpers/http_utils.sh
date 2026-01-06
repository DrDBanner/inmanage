#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HELPER_HTTP_UTILS_LOADED:-} ]] && return
__HELPER_HTTP_UTILS_LOADED=1

# ---------------------------------------------------------------------
# http_status()
# Fetch HTTP status code with https->insecure fallback.
# Consumes: args: url, insecure_var; tools: curl.
# Computes: status code and optional insecure flag.
# Returns: status code on stdout.
# ---------------------------------------------------------------------
http_status() {
    local url="$1"
    local insecure_var="$2"
    local insecure=false
    local status_code
    status_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$url")"
    if [[ "$status_code" == "000" && "$url" == https:* ]]; then
        status_code="$(curl -s -k -o /dev/null -w '%{http_code}' --connect-timeout 5 "$url")"
        if [[ "$status_code" != "000" ]]; then
            insecure=true
        fi
    fi
    if [[ -n "$insecure_var" ]]; then
        printf -v "$insecure_var" "%s" "$insecure"
    fi
    printf "%s" "$status_code"
}

# ---------------------------------------------------------------------
# http_head()
# HEAD request check with https->insecure fallback.
# Consumes: args: url, ok_var, insecure_var; tools: curl.
# Computes: ok/insecure booleans.
# Returns: 0 always (values via vars).
# ---------------------------------------------------------------------
http_head() {
    local url="$1"
    local ok_var="$2"
    local insecure_var="$3"
    local ok=false
    local insecure=false
    if curl -Is --connect-timeout 5 "$url" >/dev/null 2>&1; then
        ok=true
    elif [[ "$url" == https:* ]] && curl -Is -k --connect-timeout 5 "$url" >/dev/null 2>&1; then
        ok=true
        insecure=true
    fi
    if [[ -n "$ok_var" ]]; then
        printf -v "$ok_var" "%s" "$ok"
    fi
    if [[ -n "$insecure_var" ]]; then
        printf -v "$insecure_var" "%s" "$insecure"
    fi
}

# ---------------------------------------------------------------------
# http_head_line()
# Return the first response line from a HEAD request.
# Consumes: args: url; tools: curl.
# Computes: status line.
# Returns: line on stdout (may be empty).
# ---------------------------------------------------------------------
http_head_line() {
    local url="$1"
    local line=""
    line="$(curl -sI "$url" 2>/dev/null | head -n1)"
    printf "%s" "$line"
}

# ---------------------------------------------------------------------
# http_fetch_with_args()
# Fetch URL content with optional args and https fallback.
# Consumes: args: url, out_var, allow_http_fallback, extra curl args; tools: curl/wget.
# Computes: response body.
# Returns: 0 on success, 1 on empty/failed fetch.
# ---------------------------------------------------------------------
http_fetch_with_args() {
    local url="$1"
    local out_var="$2"
    local allow_http_fallback="${3:-false}"
    shift 3
    local -a extra_args=("$@")
    local trace_guard=false
    if declare -F trace_can_guard >/dev/null 2>&1 && trace_can_guard; then
        local arg
        for arg in "${extra_args[@]}"; do
            case "$arg" in
                -u*|--user*|Authorization:*|authorization:*|*Authorization:*|*authorization:*)
                    trace_suspend && trace_guard=true
                    break
                    ;;
            esac
        done
    fi
    local out=""
    local rc=1
    if command -v curl >/dev/null 2>&1; then
        out=$(curl -s "${extra_args[@]}" "$url" 2>/dev/null)
        rc=$?
        if [[ $rc -ne 0 || -z "$out" ]] && [[ "$url" == https:* ]]; then
            out=$(curl -s -k "${extra_args[@]}" "$url" 2>/dev/null)
            rc=$?
            if [[ ($rc -ne 0 || -z "$out") && "$allow_http_fallback" == true ]]; then
                local http_fallback="${url/https:\/\//http://}"
                out=$(curl -s "${extra_args[@]}" "$http_fallback" 2>/dev/null)
                rc=$?
            fi
        fi
    elif command -v wget >/dev/null 2>&1; then
        out=$(wget -qO- "$url" 2>/dev/null)
        rc=$?
    fi
    if [[ "$trace_guard" == true ]]; then
        trace_resume
    fi
    if [[ -n "$out_var" ]]; then
        printf -v "$out_var" "%s" "$out"
    else
        printf "%s" "$out"
    fi
    if [[ -z "$out" ]]; then
        return 1
    fi
    return "$rc"
}

# ---------------------------------------------------------------------
# http_fetch()
# Wrapper for http_fetch_with_args.
# Consumes: args: url, out_var, allow_http_fallback, extra args.
# Computes: response body.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
http_fetch() {
    http_fetch_with_args "$@"
}
