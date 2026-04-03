#!/usr/bin/env bash

# Migration 002: switch legacy default branch installs from development to main.

migration_002_checkout_main_branch() {
    local config_file="${1:-}"
    local script_path=""
    local root=""
    local current_branch=""

    if declare -F self_resolve_path >/dev/null 2>&1; then
        script_path="$(self_resolve_path "$0")"
    else
        script_path="$0"
    fi
    root="$(cd "$(dirname "$script_path")" && pwd)"

    if [[ ! -d "$root/.git" ]]; then
        return 0
    fi

    if declare -F git_collect_info >/dev/null 2>&1; then
        git_collect_info "$root" current_branch "" "" "" "" || true
    fi
    if [[ -z "$current_branch" || "$current_branch" == "unknown" ]]; then
        current_branch="$(git -c safe.directory="$root" -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi

    if [[ "$current_branch" != "development" ]]; then
        return 0
    fi

    log info "[SELF_MIG] Switching CLI checkout from development to main."

    if ! git -c safe.directory="$root" -C "$root" fetch origin; then
        log err "[SELF_MIG] Failed to fetch origin before switching to main."
        return 1
    fi
    if ! git -c safe.directory="$root" -C "$root" checkout main; then
        log err "[SELF_MIG] Failed to check out main in $root."
        return 1
    fi
    if ! git -c safe.directory="$root" -C "$root" pull --ff-only; then
        log err "[SELF_MIG] Failed to fast-forward main in $root."
        return 1
    fi

    if declare -F self_write_version_file >/dev/null 2>&1; then
        self_write_version_file "$root" "$root"
    fi

    return 0
}
