#!/usr/bin/env bash

# ---------------------------------------------------------------------
# resolve_script_path()
# Resolve a script path across symlinks.
# Consumes: args: target; tools: realpath/readlink.
# Computes: absolute path.
# Returns: path on stdout.
# ---------------------------------------------------------------------
resolve_script_path() {
    local target="$1"

    if command -v realpath >/dev/null 2>&1; then
        realpath "$target" && return
    fi

    if readlink -f "$target" >/dev/null 2>&1; then
        readlink -f "$target" && return
    fi

    (
        cd "$(dirname "$target")" 2>/dev/null || exit 1
        # shellcheck disable=SC2155
        local file="$(basename "$target")"
        while [ -L "$file" ]; do
            file="$(readlink "$file")"
            cd "$(dirname "$file")" 2>/dev/null || break
            file="$(basename "$file")"
        done
        printf "%s/%s\n" "$(pwd -P)" "$file"
    )
}

# ---------------------------------------------------------------------
# resolve_cli_command_path()
# Resolve INmanage CLI command path for cron usage.
# Consumes: env: SCRIPT_PATH/INM_BASE_DIRECTORY; tools: realpath/command.
# Computes: executable path.
# Returns: path on stdout; 1 if not found.
# ---------------------------------------------------------------------
resolve_cli_command_path() {
    local candidate
    local resolved=""
    local base_clean="${INM_BASE_DIRECTORY%/}"
    local candidates=()
    if [[ -n "${SCRIPT_PATH:-}" ]]; then
        candidates+=("$SCRIPT_PATH")
    fi
    if command -v inm >/dev/null 2>&1; then
        candidates+=("$(command -v inm)")
    fi
    if command -v inmanage >/dev/null 2>&1; then
        candidates+=("$(command -v inmanage)")
    fi
    if [[ -n "$base_clean" ]]; then
        candidates+=("${base_clean}/inmanage" "${base_clean}/inm")
    fi
    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" ]] && continue
        resolved="$(realpath "$candidate" 2>/dev/null || echo "$candidate")"
        if [ -x "$resolved" ]; then
            printf "%s" "$resolved"
            return 0
        fi
    done
    return 1
}
