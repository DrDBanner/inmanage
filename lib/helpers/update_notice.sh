#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HELPER_UPDATE_NOTICE_LOADED:-} ]] && return
__HELPER_UPDATE_NOTICE_LOADED=1

update_notice_dir() {
    local base="${INM_PATH_BASE_DIR:-}"
    [[ -n "$base" ]] || return 1
    local dir="${base%/}/.inmanage"
    [[ -d "$dir" ]] || return 1
    printf "%s" "$dir"
}

update_notice_file() {
    local kind="${1:-}"
    [[ -n "$kind" ]] || return 1
    local dir
    dir="$(update_notice_dir)" || return 1
    printf "%s/.update_notice_%s" "$dir" "$kind"
}

update_notice_check_file() {
    local dir
    dir="$(update_notice_dir)" || return 1
    printf "%s/.update_notice_checked" "$dir"
}

update_notice_last_check_ts() {
    local file ts=""
    file="$(update_notice_check_file)" || return 1
    [[ -e "$file" ]] || return 1
    if ts=$(stat -c '%Y' "$file" 2>/dev/null); then
        printf "%s" "$ts"
        return 0
    fi
    if ts=$(stat -f '%m' "$file" 2>/dev/null); then
        printf "%s" "$ts"
        return 0
    fi
    return 1
}

update_notice_mark_checked() {
    local file
    file="$(update_notice_check_file)" || return 0
    if ! mkdir -p "$(dirname "$file")" 2>/dev/null; then
        return 0
    fi
    local now
    now="$(date +%s 2>/dev/null || true)"
    [[ -n "$now" ]] || return 0
    printf "%s\n" "$now" > "$file" 2>/dev/null || return 0
    chmod "${INM_PERM_FILE_MODE:-644}" "$file" 2>/dev/null || true
    return 0
}

update_notice_should_check() {
    local force="${1:-false}"
    if declare -F args_is_true >/dev/null 2>&1; then
        if args_is_true "$force"; then
            return 0
        fi
    elif [[ "$force" == true || "$force" == "1" || "$force" == "yes" ]]; then
        return 0
    fi
    local ttl=86400
    local ts
    ts="$(update_notice_last_check_ts 2>/dev/null || true)"
    [[ -n "$ts" ]] || return 0
    local now
    now="$(date +%s 2>/dev/null || true)"
    [[ "$now" =~ ^[0-9]+$ ]] || return 0
    local age=$((now - ts))
    if [ "$age" -lt "$ttl" ]; then
        return 1
    fi
    return 0
}

update_notice_set() {
    local kind="$1"
    local level="$2"
    local message="$3"
    local file
    file="$(update_notice_file "$kind")" || return 0
    if ! mkdir -p "$(dirname "$file")" 2>/dev/null; then
        return 0
    fi
    printf "%s|%s\n" "${level,,}" "$message" > "$file" 2>/dev/null || return 0
    chmod "${INM_PERM_FILE_MODE:-644}" "$file" 2>/dev/null || true
    return 0
}

update_notice_clear() {
    local kind="$1"
    local file
    file="$(update_notice_file "$kind")" || return 0
    rm -f "$file" 2>/dev/null || true
    return 0
}

update_notice_emit_kind() {
    local kind="$1"
    local file
    file="$(update_notice_file "$kind")" || return 1
    [[ -s "$file" ]] || return 1
    local line level message
    line="$(head -n1 "$file" 2>/dev/null)"
    level="${line%%|*}"
    message="${line#*|}"
    if [[ -z "$message" || "$line" == "$level" ]]; then
        message="$line"
        level="info"
    fi
    log "${level,,}" "$message"
}

update_notice_emit() {
    update_notice_emit_kind "cli" || true
    update_notice_emit_kind "app" || true
}
