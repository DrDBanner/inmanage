#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__FS_HELPER_LOADED:-} ]] && return
__FS_HELPER_LOADED=1

fs_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fs_modules=(
    "fs_path.sh"
    "fs_safe_ops.sh"
    "fs_archive.sh"
    "fs_permissions.sh"
    "fs_log.sh"
    "fs_app.sh"
)

for module in "${fs_modules[@]}"; do
    if [[ -f "${fs_helper_dir}/${module}" ]]; then
        # shellcheck disable=SC1090
        source "${fs_helper_dir}/${module}"
    else
        log err "[FS] Missing helper module: ${fs_helper_dir}/${module}"
        return 1
    fi
done
