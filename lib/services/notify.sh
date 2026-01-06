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

# ---------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# notify_bool()
# Normalize a truthy/falsey value.
# Consumes: args: value.
# Computes: boolean decision.
# Returns: 0 for true, 1 for false.
# ---------------------------------------------------------------------
notify_bool() {
    local val="${1:-}"
    val="${val,,}"
    case "$val" in
        1|true|yes|y|on) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------
# notify_level_rank()
# Map a severity level to a numeric rank.
# Consumes: args: level.
# Computes: numeric rank.
# Returns: prints rank to stdout.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# notify_level_allows()
# Check if an event level meets a threshold.
# Consumes: args: event_level, threshold; deps: notify_level_rank.
# Computes: comparison result.
# Returns: 0 if allowed, 1 otherwise.
# ---------------------------------------------------------------------
notify_level_allows() {
    local event_level="$1"
    local threshold="$2"
    local event_rank
    local threshold_rank
    event_rank="$(notify_level_rank "$event_level")"
    threshold_rank="$(notify_level_rank "$threshold")"
    [ "$event_rank" -ge "$threshold_rank" ]
}

# ---------------------------------------------------------------------
# notify_is_interactive()
# Detect interactive TTY mode.
# Consumes: tty availability.
# Computes: boolean decision.
# Returns: 0 if interactive, 1 otherwise.
# ---------------------------------------------------------------------
notify_is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# ---------------------------------------------------------------------
# Config gating
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# notify_is_enabled()
# Check whether notifications are enabled.
# Consumes: env: INM_NOTIFY_ENABLED.
# Computes: boolean decision.
# Returns: 0 if enabled, 1 otherwise.
# ---------------------------------------------------------------------
notify_is_enabled() {
    notify_bool "${INM_NOTIFY_ENABLED:-false}"
}

# ---------------------------------------------------------------------
# notify_noninteractive_only()
# Check whether notifications are limited to non-interactive runs.
# Consumes: env: INM_NOTIFY_NONINTERACTIVE_ONLY.
# Computes: boolean decision.
# Returns: 0 if non-interactive only, 1 otherwise.
# ---------------------------------------------------------------------
notify_noninteractive_only() {
    if [ -z "${INM_NOTIFY_NONINTERACTIVE_ONLY+x}" ]; then
        return 0
    fi
    notify_bool "${INM_NOTIFY_NONINTERACTIVE_ONLY:-true}"
}

# ---------------------------------------------------------------------
# notify_should_send()
# Decide if notifications should be sent for this run.
# Consumes: args: force; deps: notify_is_enabled/notify_noninteractive_only/notify_is_interactive.
# Computes: gating decision.
# Returns: 0 if allowed, 1 otherwise.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# notify_resolve_targets()
# Resolve notification targets from config.
# Consumes: env: INM_NOTIFY_TARGETS, INM_NOTIFY_EMAIL_TO.
# Computes: target list string.
# Returns: prints targets.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# notify_host_label()
# Get the host label for notifications.
# Consumes: hostname.
# Computes: short hostname.
# Returns: prints host label.
# ---------------------------------------------------------------------
notify_host_label() {
    hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown"
}

# ---------------------------------------------------------------------
# notify_format_subject()
# Build the notification email subject.
# Consumes: args: title, status; deps: notify_host_label.
# Computes: subject string.
# Returns: prints subject.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# notify_format_body()
# Build the notification body (plain/HTML).
# Consumes: args: title, status, counts, details; deps: notify_email_format_html.
# Computes: plain and HTML body content.
# Returns: prints plain body; sets NOTIFY_BODY_HTML.
# ---------------------------------------------------------------------
notify_format_body() {
    local title="$1"
    local status="${2:-}"
    local counts="${3:-}"
    local details="${4:-}"
    local host
    host="$(notify_host_label)"
    local run_user
    run_user="$(id -un 2>/dev/null || whoami 2>/dev/null || echo "unknown")"
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
    rows+=("User|$run_user")
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

# ---------------------------------------------------------------------
# notify_build_summary()
# Build a notification summary string.
# Consumes: args: counts, status.
# Computes: summary string.
# Returns: prints summary.
# ---------------------------------------------------------------------
notify_build_summary() {
    local details="${1:-}"
    if [ -n "$details" ]; then
        printf "%s" "$details"
    fi
}

# ---------------------------------------------------------------------
# notify_counts_line()
# Build a counts line for OK/WARN/ERR.
# Consumes: args: ok, warn, err.
# Computes: counts string.
# Returns: prints counts line.
# ---------------------------------------------------------------------
notify_counts_line() {
    local ok="$1"
    local warn="$2"
    local err="$3"
    printf "OK=%s WARN=%s ERR=%s" "$ok" "$warn" "$err"
}

# ---------------------------------------------------------------------
# Transports
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# notify_transport_email()
# Send a notification via email.
# Consumes: args: subject, body, body_html; deps: notify_send_email.
# Computes: email transport call.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
notify_transport_email() {
    notify_send_email "$@"
}

# ---------------------------------------------------------------------
# notify_transport_webhook()
# Send a notification via webhook.
# Consumes: args: subject, body; deps: notify_send_webhook.
# Computes: webhook transport call.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
notify_transport_webhook() {
    notify_send_webhook "$@"
}

# ---------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# notify_send_targets()
# Send a notification to selected targets.
# Consumes: args: subject, body, body_html, targets; deps: notify_transport_email/notify_transport_webhook.
# Computes: dispatch per target.
# Returns: 0 if all succeed, non-zero otherwise.
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
        if [ -z "$t" ]; then
            continue
        fi
        case "$t" in
            email)
                notify_transport_email "$subject" "$body" "$body_html" && sent_any=true
                ;;
            webhook)
                notify_transport_webhook "$subject" "$body" && sent_any=true
                ;;
            *)
                log warn "[NOTIFY] Unknown target: $t"
                ;;
        esac
    done
    if $sent_any; then
        # shellcheck disable=SC2034
        declare -g INM_NOTIFY_SENT=true
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# notify_emit_event()
# Emit a notification event.
# Consumes: args: level, title, details, force; env: INM_NOTIFY_LEVEL; deps: notify_should_send.
# Computes: formatted subject/body and target dispatch.
# Returns: 0 on success, non-zero on failure.
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
    body_html="$(notify_email_format_html "$title" "$level" "" "$details")"
    notify_send_targets "$subject" "$body" "$body_html"
}

# ---------------------------------------------------------------------
# notify_emit_heartbeat()
# Emit a heartbeat notification with health output.
# Consumes: args: title, ok, warn, err, details; env: INM_NOTIFY_HEARTBEAT_LEVEL.
# Computes: heartbeat subject/body and sends notification.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
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
    body_html="$(notify_email_format_html "Heartbeat" "$aggregate" "$counts" "$summary")"
    notify_send_targets "$subject" "$body" "$body_html"
}

# ---------------------------------------------------------------------
# notify_send_test()
# Send a test notification using current settings.
# Consumes: args: title, details; deps: notify_emit_event.
# Computes: test notification dispatch.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
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
    body_html="$(notify_email_format_html "Notification test" "$aggregate" "$counts" "$summary")"
    notify_send_targets "$subject" "$body" "$body_html"
}
