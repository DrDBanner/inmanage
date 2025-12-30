#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__ENV_READ_HELPER_LOADED:-} ]] && return
__ENV_READ_HELPER_LOADED=1

# ---------------------------------------------------------------------
# read_env_value()
# Simple env reader with safe fallback if read_env_value_safe is present.
# ---------------------------------------------------------------------
read_env_value() {
    local file="$1"
    local key="$2"
    if declare -F read_env_value_safe >/dev/null 2>&1; then
        read_env_value_safe "$file" "$key" || true
        return 0
    fi
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' ' || true
}
