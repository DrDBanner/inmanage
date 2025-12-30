#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__NOTIFY_WEBHOOK_HELPER_LOADED:-} ]] && return
__NOTIFY_WEBHOOK_HELPER_LOADED=1

# ---------------------------------------------------------------------
# Webhook transport
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
    if ! curl -sS -X POST -H "Content-Type: text/plain" \
        -H "X-Inmanage-Subject: ${subject}" \
        --data-raw "$body" "$url" >/dev/null 2>&1; then
        log warn "[NOTIFY] Webhook delivery failed."
        return 1
    fi
    log ok "[NOTIFY] Webhook delivered."
    return 0
}
