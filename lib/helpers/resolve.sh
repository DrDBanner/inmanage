#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__RESOLVE_HELPER_LOADED:-} ]] && return
__RESOLVE_HELPER_LOADED=1

resolve_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve_modules=(
    "resolve_paths.sh"
    "resolve_utils.sh"
    "resolve_env.sh"
    "resolve_cache.sh"
)

for module in "${resolve_modules[@]}"; do
    if [[ -f "${resolve_helper_dir}/${module}" ]]; then
        # shellcheck disable=SC1090
        source "${resolve_helper_dir}/${module}"
    else
        log err "[RES] Missing helper module: ${resolve_helper_dir}/${module}"
        return 1
    fi
done
