#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__ENV_READ_HELPER_LOADED:-} ]] && return
__ENV_READ_HELPER_LOADED=1

# ---------------------------------------------------------------------
# read_env_value()
# Read a key from an env file with safe parsing fallback.
# Consumes: args: file, key; deps: read_env_value_safe/_env_parse_env_value (optional).
# Computes: value string (trim/quote handling).
# Returns: value on stdout (empty if missing).
# ---------------------------------------------------------------------
read_env_value() {
    local file="$1"
    local key="$2"
    read_env_value_safe "$file" "$key" || true
}

# ---------------------------------------------------------------------
# env_set_file_value()
# Set a key=value in an env file via env_set helper.
# Consumes: args: file, key, value; deps: env_set.
# Computes: file update through env_set.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
env_set_file_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    INM_PATH_APP_ENV_FILE="$file" env_set app "${key}=${value}" >/dev/null || return 1
    return 0
}
