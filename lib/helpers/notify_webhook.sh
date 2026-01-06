#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__NOTIFY_WEBHOOK_HELPER_LOADED:-} ]] && return
__NOTIFY_WEBHOOK_HELPER_LOADED=1

notify_webhook_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
notify_webhook_modules=(
    "notify_webhook_format.sh"
    "notify_webhook_send.sh"
)

for module in "${notify_webhook_modules[@]}"; do
    if [[ -f "${notify_webhook_helper_dir}/${module}" ]]; then
        # shellcheck disable=SC1090
        source "${notify_webhook_helper_dir}/${module}"
    else
        log err "[NOTIFY] Missing helper module: ${notify_webhook_helper_dir}/${module}"
        return 1
    fi
done
