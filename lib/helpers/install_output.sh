#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__INSTALL_OUTPUT_HELPER_LOADED:-} ]] && return
__INSTALL_OUTPUT_HELPER_LOADED=1

install_output_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_output_modules=(
    "install_output_cron.sh"
    "install_output_summary.sh"
)

for module in "${install_output_modules[@]}"; do
    if [[ -f "${install_output_helper_dir}/${module}" ]]; then
        # shellcheck disable=SC1090
        source "${install_output_helper_dir}/${module}"
    else
        log err "[INSTALL] Missing helper module: ${install_output_helper_dir}/${module}"
        return 1
    fi
done
