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
    local line raw val
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" 2>/dev/null | tail -n1)"
    [[ -z "$line" ]] && return 0
    raw="${line#*=}"
    if declare -F _env_parse_env_value >/dev/null 2>&1; then
        local sensitive=false
        if declare -F _env_key_is_sensitive >/dev/null 2>&1 && _env_key_is_sensitive "$key"; then
            sensitive=true
        fi
        val="$(_env_parse_env_value "$raw" "$sensitive")"
    else
        val="${raw%$'\r'}"
        val="${val#"${val%%[![:space:]]*}"}"
        if [[ "$val" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "$val" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
            val="${BASH_REMATCH[1]}"
        else
            val="${val%%#*}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
    fi
    printf "%s" "$val" || true
}
