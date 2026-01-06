#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__NOTIFY_EMAIL_HELPER_LOADED:-} ]] && return
__NOTIFY_EMAIL_HELPER_LOADED=1

notify_env_helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/env_read.sh"
# shellcheck source=/dev/null
[ -f "$notify_env_helper_path" ] && {
    source "$notify_env_helper_path"
    __INM_LOADED_FILES="${__INM_LOADED_FILES:+$__INM_LOADED_FILES:}$notify_env_helper_path"
}

notify_email_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
notify_email_modules=(
    "notify_email_format.sh"
    "notify_email_send.sh"
)

for module in "${notify_email_modules[@]}"; do
    if [[ -f "${notify_email_helper_dir}/${module}" ]]; then
        # shellcheck disable=SC1090
        source "${notify_email_helper_dir}/${module}"
    else
        log err "[NOTIFY] Missing helper module: ${notify_email_helper_dir}/${module}"
        return 1
    fi
done
