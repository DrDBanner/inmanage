#!/usr/bin/env bash

# ---------------------------------------------------------------------
# notify_send_webhook()
# Send a webhook notification.
# Consumes: args: subject, body; env: INM_NOTIFY_WEBHOOK_URL; deps: notify_webhook_content_type/notify_webhook_payload.
# Computes: HTTPS POST payload.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
notify_send_webhook() {
    local subject="$1"
    local body="$2"
    local url="${INM_NOTIFY_WEBHOOK_URL:-}"
    if [ -z "$url" ]; then
        log warn "[NOTIFY] Webhook target missing (INM_NOTIFY_WEBHOOK_URL)."
        return 1
    fi
    case "$url" in
        https://*) ;;
        *)
            log err "[NOTIFY] Webhook URL must use https."
            return 1
            ;;
    esac

    local content_type payload
    content_type="$(notify_webhook_content_type)"
    payload="$(notify_webhook_payload "$subject" "$body")"
    http_curl "WEBHOOK" "$url" -s -X POST -H "Content-Type: ${content_type}" \
        -H "X-Inmanage-Subject: ${subject}" \
        --data-raw "$payload" -o /dev/null
    if [[ $? -ne 0 ]]; then
        log warn "[NOTIFY] Webhook delivery failed."
        return 1
    fi
    log ok "[NOTIFY] Webhook delivered."
    return 0
}
