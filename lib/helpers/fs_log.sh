#!/usr/bin/env bash

# ---------------------------------------------------------------------
# ops_log_resolve_dir()
# Resolve base directory for history log storage.
# Consumes: env: INM_BASE_DIRECTORY/INM_SELF_ENV_FILE.
# Computes: base dir path.
# Returns: dir on stdout; 1 if unavailable.
# ---------------------------------------------------------------------
ops_log_resolve_dir() {
    local base=""
    if [[ -n "${INM_BASE_DIRECTORY:-}" ]]; then
        base="${INM_BASE_DIRECTORY%/}/.inmanage"
    elif [[ -n "${INM_SELF_ENV_FILE:-}" ]]; then
        base="$(dirname "$INM_SELF_ENV_FILE")"
    fi
    if [[ -z "$base" ]]; then
        return 1
    fi
    printf "%s" "$base"
}

# ---------------------------------------------------------------------
# ops_log_path()
# Resolve history log file path.
# Consumes: env: INM_HISTORY_LOG_FILE/INM_BASE_DIRECTORY/INM_SELF_ENV_FILE; deps: path_expand_no_eval (optional).
# Computes: absolute log file path.
# Returns: path on stdout; 1 if unavailable.
# ---------------------------------------------------------------------
ops_log_path() {
    local path="${INM_HISTORY_LOG_FILE:-}"
    if [[ -n "$path" ]]; then
        path="$(path_expand_no_eval "$path")"
        if [[ "$path" != /* && -n "${INM_BASE_DIRECTORY:-}" ]]; then
            path="${INM_BASE_DIRECTORY%/}/${path#/}"
        fi
        printf "%s" "$path"
        return 0
    fi
    local dir
    dir="$(ops_log_resolve_dir 2>/dev/null)" || return 1
    printf "%s/history.log" "$dir"
}

# ---------------------------------------------------------------------
# ops_log_emit_preflight()
# Emit history log status for preflight output.
# Consumes: args: add_fn, fix_permissions, can_enforce; env: INM_HISTORY_LOG_*; deps: ops_log_path/enforce_ownership.
# Computes: last backup status and log readability.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
ops_log_emit_preflight() {
    local add_fn="$1"
    local fix_permissions="${2:-false}"
    local can_enforce="${3:-false}"
    local emit_fn=""
    if [[ -n "$add_fn" ]] && declare -F "$add_fn" >/dev/null 2>&1; then
        emit_fn="$add_fn"
    fi
    log_emit() {
        local status="$1"
        local detail="$2"
        if [[ -n "$emit_fn" ]]; then
            "$emit_fn" "$status" "LOG" "$detail"
        else
            case "$status" in
                OK) log info "[LOG] $detail" ;;
                WARN) log warn "[LOG] $detail" ;;
                ERR) log err "[LOG] $detail" ;;
                INFO) log info "[LOG] $detail" ;;
                *) log info "[LOG] $detail" ;;
            esac
        fi
    }

    local log_file=""
    log_file="$(ops_log_path 2>/dev/null || true)"
    if [[ -z "$log_file" || ! -f "$log_file" ]]; then
        log_emit INFO "No history log entries yet"
        return 0
    fi

    if [[ ! -r "$log_file" ]]; then
        log_emit WARN "History log not readable (${log_file}); fix ownership or run with --override-enforced-user."
        if [[ "$can_enforce" == true && "$fix_permissions" == true ]]; then
            enforce_ownership "$log_file" || true
        fi
        return 0
    fi

    local last_backup_line=""
    last_backup_line="$(awk -F ' \\| ' '$2=="backup"{line=$0} END{print line}' "$log_file")"
    if [[ -z "$last_backup_line" ]]; then
        log_emit INFO "No backup log entries yet"
        return 0
    fi

    local last_status last_ts
    last_status="$(printf "%s\n" "$last_backup_line" | awk -F ' \\| ' '{print $3}')"
    last_ts="$(printf "%s\n" "$last_backup_line" | awk -F ' \\| ' '{print $1}')"
    if [[ "$last_status" == "OK" ]]; then
        log_emit OK "Last backup OK (${last_ts})"
    else
        local recent_lines recent_summary
        recent_lines="$(awk -F ' \\| ' '$2=="backup"{lines[++n]=$0} END{start=n-2; if (start<1) start=1; for (i=start; i<=n; i++) print lines[i]}' "$log_file")"
        recent_summary="$(printf "%s\n" "$recent_lines" | awk 'BEGIN{ORS=""} {if (NR>1) printf " | "; printf "%s", $0} END{print ""}')"
        log_emit ERR "Last backup failed (${last_ts}); recent backup jobs: ${recent_summary}"
    fi
}

# ---------------------------------------------------------------------
# ops_log_write()
# Append a sanitized operational event to history log.
# Consumes: args: action, status, rc, duration; env: INM_HISTORY_LOG_*; deps: ops_log_path/ops_log_rotate_if_needed.
# Computes: log line append; sudo fallback if needed.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
ops_log_write() {
    local action="$1"
    local status="$2"
    local rc="${3:-0}"
    local duration="${4:-}"
    if [[ -z "$action" || -z "$status" ]]; then
        return 1
    fi
    local log_file log_dir
    log_file="$(ops_log_path 2>/dev/null)" || return 1
    log_dir="$(dirname "$log_file")"
    local ts line
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    line="${ts} | ${action} | ${status} | rc=${rc}"
    if [[ -n "$duration" ]]; then
        line+=" | dur=${duration}s"
    fi
    if [[ -n "${INM_OPS_LOG_RUN_ID:-}" ]]; then
        line+=" | run=${INM_OPS_LOG_RUN_ID}"
    fi
    local direct_write=false
    if [[ -e "$log_file" ]]; then
        [[ -w "$log_file" ]] && direct_write=true
    else
        if [[ -d "$log_dir" ]]; then
            [[ -w "$log_dir" ]] && direct_write=true
        else
            local parent_dir
            parent_dir="$(dirname "$log_dir")"
            [[ -w "$parent_dir" ]] && direct_write=true
        fi
    fi

    if [[ "$direct_write" == true ]]; then
        mkdir -p "$log_dir" 2>/dev/null || return 1
        if [[ ! -f "$log_file" ]]; then
            touch "$log_file" 2>/dev/null || return 1
            chmod 600 "$log_file" 2>/dev/null || true
        fi
        ops_log_rotate_if_needed "$log_file"
        printf '%s\n' "$line" >> "$log_file" 2>/dev/null || return 1
    else
        local write_user=""
        if [[ -n "${INM_ENFORCED_USER:-}" ]]; then
            write_user="${INM_ENFORCED_USER}"
        elif [[ -f "$log_file" ]]; then
            local og
            og="$(_fs_get_owner "$log_file")"
            write_user="${og%%:*}"
        elif [[ -d "$log_dir" ]]; then
            local og
            og="$(_fs_get_owner "$log_dir")"
            write_user="${og%%:*}"
        fi
        if [[ -n "$write_user" && "$write_user" != "$(id -un 2>/dev/null || true)" ]] && command -v sudo >/dev/null 2>&1; then
            if sudo -n -u "$write_user" true 2>/dev/null; then
                local max_raw="${INM_HISTORY_LOG_MAX_SIZE:-}"
                local rotate="${INM_HISTORY_LOG_ROTATE:-0}"
                sudo -n -u "$write_user" sh -c '
log_file="$1"
max_raw="$2"
rotate="$3"
line="$4"
mkdir -p "$(dirname "$log_file")" || exit 1
if [ ! -f "$log_file" ]; then
  touch "$log_file" || exit 1
  chmod 600 "$log_file" || true
fi
if [ -n "$max_raw" ] && [ "$max_raw" != "0" ] && [ -n "$rotate" ] && [ "$rotate" != "0" ]; then
  max_bytes="$max_raw"
  case "$max_raw" in
    *[Kk]) max_bytes=$(( ${max_raw%[Kk]} * 1024 ));;
    *[Mm]) max_bytes=$(( ${max_raw%[Mm]} * 1024 * 1024 ));;
    *[Gg]) max_bytes=$(( ${max_raw%[Gg]} * 1024 * 1024 * 1024 ));;
  esac
  if [ -n "$max_bytes" ]; then
    size=$(wc -c < "$log_file" 2>/dev/null || echo "")
    if [ -n "$size" ] && [ "$size" -ge "$max_bytes" ]; then
      i=$((rotate-1))
      while [ "$i" -ge 1 ]; do
        if [ -f "${log_file}.$i" ]; then
          mv -f "${log_file}.$i" "${log_file}.$((i+1))"
        fi
        i=$((i-1))
      done
      mv -f "$log_file" "${log_file}.1" 2>/dev/null || true
      touch "$log_file" 2>/dev/null || true
      chmod 600 "$log_file" 2>/dev/null || true
    fi
  fi
fi
printf "%s\n" "$line" >> "$log_file"
' sh "$log_file" "$max_raw" "$rotate" "$line" 2>/dev/null || {
                    log warn "[LOG] Failed to write history log via sudo."
                    return 1
                }
            else
                log warn "[LOG] History log not writable; passwordless sudo not available."
                return 1
            fi
        else
            log warn "[LOG] History log not writable; adjust ownership or run with --override-enforced-user."
            return 1
        fi
    fi
    INM_OPS_LOG_WROTE=true
}

# ---------------------------------------------------------------------
# ops_log_parse_size()
# Parse size string (bytes/K/M/G) into bytes.
# Consumes: args: size.
# Computes: byte count.
# Returns: bytes on stdout (empty if invalid).
# ---------------------------------------------------------------------
ops_log_parse_size() {
    local raw="$1"
    [[ -z "$raw" ]] && return 1
    raw="$(printf "%s" "$raw" | tr -d ' ')"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf "%s" "$raw"
        return 0
    fi
    if [[ "$raw" =~ ^([0-9]+)([KkMmGg])$ ]]; then
        local val="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        case "$unit" in
            K|k) printf "%s" $((val * 1024));;
            M|m) printf "%s" $((val * 1024 * 1024));;
            G|g) printf "%s" $((val * 1024 * 1024 * 1024));;
        esac
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# ops_log_rotate_if_needed()
# Rotate log when exceeding max size.
# Consumes: args: log_file; env: INM_HISTORY_LOG_MAX_SIZE/INM_HISTORY_LOG_ROTATE.
# Computes: rotation via renames.
# Returns: 0 always.
# ---------------------------------------------------------------------
ops_log_rotate_if_needed() {
    local log_file="$1"
    [[ -z "$log_file" || ! -f "$log_file" ]] && return 0
    local max_raw="${INM_HISTORY_LOG_MAX_SIZE:-}"
    [[ -z "$max_raw" || "$max_raw" == "0" ]] && return 0
    local max_bytes=""
    max_bytes="$(ops_log_parse_size "$max_raw" 2>/dev/null || true)"
    [[ -z "$max_bytes" ]] && return 0
    local size=""
    size="$(wc -c < "$log_file" 2>/dev/null || true)"
    [[ -z "$size" ]] && return 0
    if [[ "$size" -lt "$max_bytes" ]]; then
        return 0
    fi
    local rotate="${INM_HISTORY_LOG_ROTATE:-0}"
    if [[ -z "$rotate" || "$rotate" == "0" ]]; then
        return 0
    fi
    if ! [[ "$rotate" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    local i
    for ((i=rotate-1; i>=1; i--)); do
        if [[ -f "${log_file}.${i}" ]]; then
            mv -f "${log_file}.${i}" "${log_file}.$((i+1))" 2>/dev/null || true
        fi
    done
    mv -f "$log_file" "${log_file}.1" 2>/dev/null || return 0
    touch "$log_file" 2>/dev/null || true
    chmod 600 "$log_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------
# ops_log_begin()
# Mark start of an operation for duration tracking.
# Consumes: args: action; env: INM_HISTORY_LOG_ENABLED.
# Computes: timestamp marker in temp file.
# Returns: 0 always.
# ---------------------------------------------------------------------
ops_log_begin() {
    local action="$1"
    if [[ -z "$action" ]]; then
        return 1
    fi
    INM_OPS_LOG_ACTIVE=true
    INM_OPS_LOG_ACTION="$action"
    INM_OPS_LOG_STARTED="$(date +%s)"
}

# ---------------------------------------------------------------------
# ops_log_end()
# Write completion entry with duration.
# Consumes: args: action, status, rc; deps: ops_log_write.
# Computes: duration if start marker exists.
# Returns: 0 always.
# ---------------------------------------------------------------------
ops_log_end() {
    local rc="${1:-0}"
    if [[ "${INM_OPS_LOG_ACTIVE:-}" != "true" ]]; then
        return 0
    fi
    local start="${INM_OPS_LOG_STARTED:-}"
    local duration=""
    if [[ -n "$start" ]]; then
        duration="$(( $(date +%s) - start ))"
    fi
    local status="OK"
    if [[ "$rc" -ne 0 ]]; then
        status="ERR"
    fi
    INM_OPS_LOG_ACTIVE=false
    ops_log_write "${INM_OPS_LOG_ACTION:-unknown}" "$status" "$rc" "$duration"
    INM_OPS_LOG_ACTION=""
    INM_OPS_LOG_STARTED=""
}

# ---------------------------------------------------------------------
# ops_log_on_error()
# Write error entry for a failed action.
# Consumes: args: action, rc; deps: ops_log_write.
# Computes: error log line.
# Returns: 0 always.
# ---------------------------------------------------------------------
ops_log_on_error() {
    local rc=$?
    if [[ "${INM_OPS_LOG_ACTIVE:-}" == "true" ]]; then
        local start="${INM_OPS_LOG_STARTED:-}"
        local duration=""
        if [[ -n "$start" ]]; then
            duration="$(( $(date +%s) - start ))"
        fi
        INM_OPS_LOG_ACTIVE=false
        ops_log_write "${INM_OPS_LOG_ACTION:-unknown}" "ERR" "$rc" "$duration"
        INM_OPS_LOG_ACTION=""
        INM_OPS_LOG_STARTED=""
    elif [[ "${INM_OPS_LOG_FALLBACK_ACTIVE:-}" == "true" && "${INM_OPS_LOG_WROTE:-}" != "true" ]]; then
        local fstart="${INM_OPS_LOG_FALLBACK_STARTED:-}"
        local fduration=""
        if [[ -n "$fstart" ]]; then
            fduration="$(( $(date +%s) - fstart ))"
        fi
        INM_OPS_LOG_FALLBACK_ACTIVE=false
        ops_log_write "${INM_OPS_LOG_FALLBACK_ACTION:-unknown}" "ERR" "$rc" "$fduration"
        INM_OPS_LOG_FALLBACK_ACTION=""
        INM_OPS_LOG_FALLBACK_STARTED=""
    fi
    return "$rc"
}

# ---------------------------------------------------------------------
# history_log_append()
# Writes a detailed line to history log (no recursion into log()).
# Format: "ts | action | level | message"
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# history_log_append()
# Backward-compatible wrapper for ops_log_write.
# Consumes: args: action, status, rc, duration.
# Computes: log append.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
history_log_append() {
    local action="$1"
    local level="$2"
    local message="$3"
    if [[ -z "$action" || -z "$level" || -z "$message" ]]; then
        return 1
    fi
    local log_file
    log_file="$(ops_log_path 2>/dev/null)" || return 1
    local log_dir
    log_dir="$(dirname "$log_file")"
    local ts line
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    message="${message//$'\n'/ }"
    message="${message// | / / }"
    if declare -F log_redact_emails >/dev/null 2>&1; then
        message="$(log_redact_emails "$message")"
    fi
    line="${ts} | ${action} | ${level} | ${message}"
    # Avoid sensitive values in history details.
    if printf '%s' "$line" | grep -Eqi '(PASSWORD=|PASS=|_PASSWORD|MAIL_PASSWORD|DB_PASSWORD|API_KEY|SECRET|TOKEN)'; then
        return 0
    fi

    if [[ -e "$log_file" ]]; then
        if [[ -w "$log_file" ]]; then
            printf '%s\n' "$line" >> "$log_file" 2>/dev/null || return 1
            return 0
        fi
    else
        if [[ -d "$log_dir" && -w "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || return 1
            touch "$log_file" 2>/dev/null || return 1
            chmod 600 "$log_file" 2>/dev/null || true
            printf '%s\n' "$line" >> "$log_file" 2>/dev/null || return 1
            return 0
        fi
    fi

    local write_user=""
    if [[ -n "${INM_ENFORCED_USER:-}" ]]; then
        write_user="${INM_ENFORCED_USER}"
    elif [[ -f "$log_file" ]]; then
        local og
        og="$(_fs_get_owner "$log_file")"
        write_user="${og%%:*}"
    elif [[ -d "$log_dir" ]]; then
        local og
        og="$(_fs_get_owner "$log_dir")"
        write_user="${og%%:*}"
    fi

    if [[ -n "$write_user" && "$write_user" != "$(id -un 2>/dev/null || true)" ]] && command -v sudo >/dev/null 2>&1; then
        if sudo -n -u "$write_user" true 2>/dev/null; then
            sudo -n -u "$write_user" sh -c '
log_file="$1"
line="$2"
mkdir -p "$(dirname "$log_file")" || exit 1
if [ ! -f "$log_file" ]; then
  touch "$log_file" || exit 1
  chmod 600 "$log_file" || true
fi
printf "%s\n" "$line" >> "$log_file"
' sh "$log_file" "$line" 2>/dev/null || return 1
            return 0
        fi
    fi
    return 1
}

# ---------------------------------------------------------------------
# ops_log_fallback_begin()
# Fallback marker for legacy log tracking.
# Consumes: args: action.
# Computes: temp marker file.
# Returns: 0 always.
# ---------------------------------------------------------------------
ops_log_fallback_begin() {
    local action="$1"
    [[ -z "$action" ]] && return 1
    INM_OPS_LOG_FALLBACK_ACTIVE=true
    INM_OPS_LOG_FALLBACK_ACTION="$action"
    INM_OPS_LOG_FALLBACK_STARTED="$(date +%s)"
}

# ---------------------------------------------------------------------
# ops_log_fallback_end()
# Fallback completion entry for legacy log tracking.
# Consumes: args: action, status, rc.
# Computes: writes via ops_log_write.
# Returns: 0 always.
# ---------------------------------------------------------------------
ops_log_fallback_end() {
    local rc="${1:-0}"
    if [[ "${INM_OPS_LOG_FALLBACK_ACTIVE:-}" != "true" ]]; then
        return 0
    fi
    INM_OPS_LOG_FALLBACK_ACTIVE=false
    if [[ "${INM_OPS_LOG_WROTE:-}" == "true" ]]; then
        INM_OPS_LOG_FALLBACK_ACTION=""
        INM_OPS_LOG_FALLBACK_STARTED=""
        return 0
    fi
    local status="OK"
    if [[ "$rc" -ne 0 ]]; then
        status="ERR"
    fi
    local fstart="${INM_OPS_LOG_FALLBACK_STARTED:-}"
    local fduration=""
    if [[ -n "$fstart" ]]; then
        fduration="$(( $(date +%s) - fstart ))"
    fi
    ops_log_write "${INM_OPS_LOG_FALLBACK_ACTION:-unknown}" "$status" "$rc" "$fduration"
    INM_OPS_LOG_FALLBACK_ACTION=""
    INM_OPS_LOG_FALLBACK_STARTED=""
}
