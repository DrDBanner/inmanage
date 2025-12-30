#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_NOTIFY_LOADED:-} ]] && return
__SERVICE_NOTIFY_LOADED=1

notify_email_helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/notify_email.sh"
# shellcheck source=/dev/null
[ -f "$notify_email_helper_path" ] && {
    source "$notify_email_helper_path"
    __INM_LOADED_FILES="${__INM_LOADED_FILES:+$__INM_LOADED_FILES:}$notify_email_helper_path"
}

notify_webhook_helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/notify_webhook.sh"
# shellcheck source=/dev/null
[ -f "$notify_webhook_helper_path" ] && {
    source "$notify_webhook_helper_path"
    __INM_LOADED_FILES="${__INM_LOADED_FILES:+$__INM_LOADED_FILES:}$notify_webhook_helper_path"
}

# Fallback if email helper is missing
if ! declare -F notify_send_email >/dev/null 2>&1; then
    notify_send_email() {
        log err "[NOTIFY] Email helper missing; cannot send email."
        return 1
    }
fi
if ! declare -F notify_send_webhook >/dev/null 2>&1; then
    notify_send_webhook() {
        log err "[NOTIFY] Webhook helper missing; cannot send webhook."
        return 1
    }
fi

# ---------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------
notify_bool() {
    local val="${1:-}"
    val="${val,,}"
    case "$val" in
        1|true|yes|y|on) return 0 ;;
    esac
    return 1
}

notify_level_rank() {
    local level="${1^^}"
    case "$level" in
        ERR) echo 3 ;;
        WARN) echo 2 ;;
        INFO) echo 1 ;;
        OK) echo 0 ;;
        ALL) echo 0 ;;
        *) echo 0 ;;
    esac
}

notify_level_allows() {
    local event_level="$1"
    local threshold="$2"
    local event_rank
    local threshold_rank
    event_rank="$(notify_level_rank "$event_level")"
    threshold_rank="$(notify_level_rank "$threshold")"
    [ "$event_rank" -ge "$threshold_rank" ]
}

notify_is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# ---------------------------------------------------------------------
# Config gating
# ---------------------------------------------------------------------
notify_is_enabled() {
    notify_bool "${INM_NOTIFY_ENABLED:-false}"
}

notify_noninteractive_only() {
    if [ -z "${INM_NOTIFY_NONINTERACTIVE_ONLY+x}" ]; then
        return 0
    fi
    notify_bool "${INM_NOTIFY_NONINTERACTIVE_ONLY:-true}"
}

notify_should_send() {
    local force="${1:-false}"
    if ! notify_is_enabled; then
        return 1
    fi
    if notify_noninteractive_only && notify_is_interactive && [[ "$force" != "true" ]]; then
        return 1
    fi
    return 0
}

notify_resolve_targets() {
    local targets="${INM_NOTIFY_TARGETS:-}"
    targets="${targets//[[:space:]]/}"
    if [ -z "$targets" ] && [ -n "${INM_NOTIFY_EMAIL_TO:-}" ]; then
        targets="email"
    fi
    printf "%s" "$targets"
}

# ---------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------
notify_host_label() {
    hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown"
}

notify_format_subject() {
    local title="$1"
    local status="${2:-}"
    local host
    host="$(notify_host_label)"
    local subject="[${host}]"
    if [ -n "$status" ]; then
        subject="${subject}[${status}]"
    fi
    if [ -n "${APP_URL:-}" ]; then
        subject="${subject}[${APP_URL%/}]"
    fi
    printf "%s %s" "$subject" "$title"
}

notify_format_body() {
    local title="$1"
    local status="${2:-}"
    local counts="${3:-}"
    local details="${4:-}"
    local host
    host="$(notify_host_label)"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local rows=()
    rows+=("Event|$title")
    if [ -n "$status" ]; then
        rows+=("Status|$status")
    fi
    if [ -n "$counts" ]; then
        rows+=("Counts|$counts")
    fi
    rows+=("Host|$host")
    if [ -n "${INM_BASE_DIRECTORY:-}" ]; then
        rows+=("Base|${INM_BASE_DIRECTORY%/}")
    fi
    if [ -n "${APP_URL:-}" ]; then
        rows+=("APP_URL|${APP_URL%/}")
    fi
    rows+=("Timestamp|$ts")

    local max_len=0 label
    local row
    for row in "${rows[@]}"; do
        label="${row%%|*}"
        if [ ${#label} -gt "$max_len" ]; then
            max_len=${#label}
        fi
    done
    for row in "${rows[@]}"; do
        label="${row%%|*}"
        printf "%-${max_len}s : %s\n" "$label" "${row#*|}"
    done
    if [ -n "$details" ]; then
        printf "\n%s\n" "$details"
    fi
}

notify_build_summary() {
    local details="${1:-}"
    if [ -n "$details" ]; then
        printf "%s" "$details"
    fi
}

notify_counts_line() {
    local ok="$1"
    local warn="$2"
    local err="$3"
    printf "OK=%s WARN=%s ERR=%s" "$ok" "$warn" "$err"
}

# ---------------------------------------------------------------------
# Transports
# ---------------------------------------------------------------------
notify_transport_email() {
    notify_send_email "$@"
}

notify_transport_webhook() {
    notify_send_webhook "$@"
}

# ---------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------
notify_send_targets() {
    local subject="$1"
    local body="$2"
    local body_html="${3:-}"
    local targets
    targets="$(notify_resolve_targets)"
    if [ -z "$targets" ]; then
        log warn "[NOTIFY] No notification targets configured."
        return 1
    fi
    IFS=',' read -ra target_list <<<"$targets"
    local sent_any=false
    local t
    for t in "${target_list[@]}"; do
        t="${t,,}"
        local handler="notify_transport_${t}"
        if [ -z "$t" ]; then
            continue
        fi
        if declare -F "$handler" >/dev/null 2>&1; then
            if [[ "$t" == "email" ]]; then
                "$handler" "$subject" "$body" "$body_html" && sent_any=true
            else
                "$handler" "$subject" "$body" && sent_any=true
            fi
        else
            log warn "[NOTIFY] Unknown target: $t"
        fi
    done
    $sent_any && return 0
    return 1
}

# ---------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------
notify_emit_event() {
    local level="$1"
    local title="$2"
    local details="${3:-}"
    local force="${4:-false}"
    local threshold="${INM_NOTIFY_LEVEL:-ERR}"
    if ! notify_should_send "$force"; then
        return 0
    fi
    if ! notify_level_allows "$level" "$threshold" && [[ "$force" != "true" ]]; then
        return 0
    fi
    local subject body body_html=""
    subject="$(notify_format_subject "$title" "$level")"
    body="$(notify_format_body "$title" "$level" "" "$details")"
    if declare -F notify_email_format_html >/dev/null 2>&1; then
        body_html="$(notify_email_format_html "$title" "$level" "" "$details")"
    fi
    notify_send_targets "$subject" "$body" "$body_html"
}

notify_emit_heartbeat() {
    local aggregate="$1"
    local ok="$2"
    local warn="$3"
    local err="$4"
    local details="${5:-}"
    if ! notify_bool "${INM_NOTIFY_HEARTBEAT_ENABLED:-false}"; then
        log debug "[NOTIFY] Heartbeat disabled; skipping."
        return 0
    fi
    if ! notify_should_send false; then
        return 0
    fi
    local level="${INM_NOTIFY_HEARTBEAT_LEVEL:-ERR}"
    if ! notify_level_allows "$aggregate" "$level"; then
        return 0
    fi
    local summary counts
    summary="$(notify_build_summary "$details")"
    counts="$(notify_counts_line "$ok" "$warn" "$err")"
    local subject body body_html=""
    subject="$(notify_format_subject "Heartbeat" "$aggregate")"
    body="$(notify_format_body "Heartbeat" "$aggregate" "$counts" "$summary")"
    if declare -F notify_email_format_html >/dev/null 2>&1; then
        body_html="$(notify_email_format_html "Heartbeat" "$aggregate" "$counts" "$summary")"
    fi
    notify_send_targets "$subject" "$body" "$body_html"
}

notify_send_test() {
    local aggregate="$1"
    local ok="$2"
    local warn="$3"
    local err="$4"
    local details="${5:-}"
    if ! notify_is_enabled; then
        log warn "[NOTIFY] Notifications disabled (set INM_NOTIFY_ENABLED=true)."
        return 1
    fi
    local summary counts
    summary="$(notify_build_summary "$details")"
    counts="$(notify_counts_line "$ok" "$warn" "$err")"
    local subject body body_html=""
    subject="$(notify_format_subject "Notification test" "$aggregate")"
    body="$(notify_format_body "Notification test" "$aggregate" "$counts" "$summary")"
    if declare -F notify_email_format_html >/dev/null 2>&1; then
        body_html="$(notify_email_format_html "Notification test" "$aggregate" "$counts" "$summary")"
    fi
    notify_send_targets "$subject" "$body" "$body_html"
}
