#!/usr/bin/env bash

# ---------------------------------------------------------------------
# notify_webhook_content_type()
# Return content type for webhook payloads.
# Consumes: none.
# Computes: content type string.
# Returns: content type on stdout.
# ---------------------------------------------------------------------
notify_webhook_content_type() {
    printf "%s" "text/plain"
}

# ---------------------------------------------------------------------
# notify_webhook_payload()
# Build webhook payload.
# Consumes: args: subject, body.
# Computes: payload string.
# Returns: payload on stdout.
# ---------------------------------------------------------------------
notify_webhook_payload() {
    local body="$2"
    printf "%s" "$body"
}
