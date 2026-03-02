#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__ENV_PARSE_LOADED:-} ]] && return
__ENV_PARSE_LOADED=1

# ---------------------------------------------------------------------
# _env_unescape_double_quoted()
# Unescape \" \\ $ ` inside double-quoted values.
# Consumes: args: val.
# Computes: unescaped string.
# Returns: unescaped string on stdout.
# ---------------------------------------------------------------------
_env_unescape_double_quoted() {
    local val="$1"
    local unescaped=""
    local i=0
    local len=${#val}
    while [ $i -lt "$len" ]; do
        local ch="${val:$i:1}"
        if [ "$ch" = "\\" ] && [ $((i + 1)) -lt "$len" ]; then
            local next="${val:$((i + 1)):1}"
            case "$next" in
                "\\"|"\""|'$'|'`')
                    unescaped+="$next"
                    i=$((i + 2))
                    continue
                    ;;
            esac
        fi
        unescaped+="$ch"
        i=$((i + 1))
    done
    printf "%s" "$unescaped"
}

# ---------------------------------------------------------------------
# _env_key_is_sensitive()
# Check if a key should be treated as sensitive.
# Consumes: args: key.
# Computes: regex match.
# Returns: 0 if sensitive, 1 otherwise.
# ---------------------------------------------------------------------
_env_key_is_sensitive() {
    local key="$1"
    [[ "$key" =~ (^|_)(PASS(WORD)?|TOKEN|SECRET|KEY|CREDENTIALS)$ ]]
}

# ---------------------------------------------------------------------
# _env_mask_email_log_line()
# Mask email domains in log output (keep local part, redact domain).
# Consumes: args: line.
# Computes: sanitized line.
# Returns: sanitized line on stdout.
# ---------------------------------------------------------------------
_env_mask_email_log_line() {
    local line="$1"
    if command -v sed >/dev/null 2>&1; then
        printf "%s" "$line" | sed -E 's/([A-Za-z0-9._%+-]+)@[^[:space:],;>"]+/\1@REDACTED/g'
    else
        printf "%s" "$line"
    fi
}

# ---------------------------------------------------------------------
# _env_trim_left()
# Trim leading whitespace.
# Consumes: args: val.
# Computes: trimmed string.
# Returns: trimmed string on stdout.
# ---------------------------------------------------------------------
_env_trim_left() {
    local val="$1"
    val="${val#"${val%%[![:space:]]*}"}"
    printf "%s" "$val"
}

# ---------------------------------------------------------------------
# _env_trim_right()
# Trim trailing whitespace.
# Consumes: args: val.
# Computes: trimmed string.
# Returns: trimmed string on stdout.
# ---------------------------------------------------------------------
_env_trim_right() {
    local val="$1"
    val="${val%"${val##*[![:space:]]}"}"
    printf "%s" "$val"
}

# ---------------------------------------------------------------------
# _env_strip_inline_comment_unquoted()
# Strip inline comment if unquoted and preceded by whitespace.
# Consumes: args: val, leading_space flag.
# Computes: comment-stripped string.
# Returns: cleaned string on stdout.
# ---------------------------------------------------------------------
_env_strip_inline_comment_unquoted() {
    local val="$1"
    local leading_space="${2:-false}"
    local out=""
    local i=0
    local len=${#val}
    local prev_space="$leading_space"
    while [ $i -lt "$len" ]; do
        local ch="${val:$i:1}"
        if [[ "$ch" == "#" && "$prev_space" == true ]]; then
            break
        fi
        out+="$ch"
        if [[ "$ch" =~ [[:space:]] ]]; then
            prev_space=true
        else
            prev_space=false
        fi
        i=$((i + 1))
    done
    printf "%s" "$out"
}

# ---------------------------------------------------------------------
# _env_parse_env_value()
# Parse an env value with quoting/comment rules.
# Consumes: args: raw, sensitive flag; deps: _env_trim_* helpers.
# Computes: normalized value string.
# Returns: value on stdout.
# ---------------------------------------------------------------------
_env_parse_env_value() {
    local raw="$1"
    local sensitive="${2:-false}"
    raw="${raw%$'\r'}"
    local val
    val="$(_env_trim_left "$raw")"
    local had_leading_space=false
    if [[ "$raw" != "$val" ]]; then
        had_leading_space=true
    fi
    if [[ "$val" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
        val="$(_env_unescape_double_quoted "${BASH_REMATCH[1]}")"
        printf "%s" "$val"
        return 0
    fi
    if [[ "$val" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
        printf "%s" "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$sensitive" == true ]]; then
        val="$(_env_trim_right "$val")"
        printf "%s" "$val"
        return 0
    fi
    val="$(_env_strip_inline_comment_unquoted "$val" "$had_leading_space")"
    val="$(_env_trim_right "$val")"
    printf "%s" "$val"
}

# ---------------------------------------------------------------------
# _env_extract_inline_comment()
# Extract inline comment portion from a line.
# Consumes: args: raw.
# Computes: comment string (if present).
# Returns: comment on stdout (empty if none).
# ---------------------------------------------------------------------
_env_extract_inline_comment() {
    local raw="$1"
    raw="${raw%$'\r'}"
    if [[ "$raw" =~ ^[[:space:]]*\"(.*)\"([[:space:]]*#.*)?$ ]]; then
        [[ -n "${BASH_REMATCH[2]}" ]] && printf "%s" "${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$raw" =~ ^[[:space:]]*\'(.*)\'([[:space:]]*#.*)?$ ]]; then
        [[ -n "${BASH_REMATCH[2]}" ]] && printf "%s" "${BASH_REMATCH[2]}"
        return 0
    fi
    local i=0
    local len=${#raw}
    local seen_nonspace=false
    local prev_space=true
    local space_run_start=0
    while [ $i -lt "$len" ]; do
        local ch="${raw:$i:1}"
        if [[ "$ch" =~ [[:space:]] ]]; then
            if [[ "$prev_space" == false ]]; then
                space_run_start=$i
            fi
            prev_space=true
        else
            if [[ "$ch" == "#" && ( "$seen_nonspace" == false || "$prev_space" == true ) ]]; then
                local start="$i"
                if [[ "$prev_space" == true ]]; then
                    start="$space_run_start"
                fi
                local comment="${raw:$start}"
                [[ -n "$comment" ]] && printf "%s" "$comment"
                return 0
            fi
            seen_nonspace=true
            prev_space=false
        fi
        i=$((i + 1))
    done
    return 0
}

# ---------------------------------------------------------------------
# load_env_file_raw()
# Parse and export selected vars from an env file safely.
# Consumes: args: file; env: none; deps: _env_parse_env_value.
# Computes: exports APP_/DB_/MAIL_/INM_/... variables.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
load_env_file_raw() {
    local file="$1"
    local resolved="$file"
    if declare -F path_expand_no_eval >/dev/null 2>&1; then
        resolved="$(path_expand_no_eval "$file")"
    elif declare -F expand_placeholders >/dev/null 2>&1; then
        resolved="$(expand_placeholders "$file")"
        local home_base="${INM_ORIGINAL_HOME:-$HOME}"
        resolved="${resolved/#\~/$home_base}"
        resolved="${resolved//\$\{HOME\}/$home_base}"
        resolved="${resolved//\$HOME/$home_base}"
    fi
    file="$resolved"
    log debug "[ENV] Loading relevant vars from: $file"

    local tmpfile
    tmpfile=$(mktemp /tmp/.inm_env_XXXXXX) || {
        log err "[ENV] Failed to create temp file"
        return 1
    }
    chmod 600 "$tmpfile"

    # Parse line by line to keep complex passwords/characters intact.
    # - Skip blank and full-line comments
    # - Respect quotes: if quoted, do NOT strip inline #
    # - Unquoted values: strip inline comment and trim, then quote for export
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        # skip empty
        [[ -z "${line//[[:space:]]/}" ]] && continue
        # skip full-line comments
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" =~ ^# ]] && continue

        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            local key val raw
            key="${BASH_REMATCH[2]}"
            raw="${BASH_REMATCH[3]}"
            # filter relevant prefixes only
            if [[ ! "$key" =~ ^(APP_|DB_|ELEVATED_|MAIL_|NINJA_|PDF_|SNAPPDF_|INM_)[A-Z_]*$ ]]; then
                continue
            fi
            local sensitive=false
            if _env_key_is_sensitive "$key"; then
                sensitive=true
            fi
            val="$(_env_parse_env_value "$raw" "$sensitive")"
            printf 'export %s=%q\n' "$key" "$val" >> "$tmpfile"
        fi
    done < "$file"

    local redacted_data=""
    while IFS= read -r line; do
        local key="${line#export }"
        key="${key%%=*}"
        local display_line=""
        if _env_key_is_sensitive "$key"; then
            display_line="export ${key}=REDACTED"
        else
            display_line="$line"
        fi
        display_line="$(_env_mask_email_log_line "$display_line")"
        redacted_data+="${display_line} "
    done < "$tmpfile"
    log debug "[ENV] Parsed data: ${redacted_data% }"

    # shellcheck disable=SC1091
    # shellcheck disable=SC1090
    if ! . "$tmpfile"; then
        log err "[ENV] Failed to source vars from $tmpfile"
        rm -f "$tmpfile"
        return 1
    fi

    rm -f "$tmpfile"
    log debug "[ENV] Successfully loaded vars from: $file"
}

# ---------------------------------------------------------------------
# read_env_value_safe()
# Read a key from an env file with quote/comment handling.
# Consumes: args: file, key; deps: _env_parse_env_value.
# Computes: value string.
# Returns: value on stdout (empty if missing).
# ---------------------------------------------------------------------
read_env_value_safe() {
    local file="$1"
    local key="$2"
    local line val raw
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" 2>/dev/null | tail -n1)"
    [[ -z "$line" ]] && return 0
    raw="${line#*=}"
    local sensitive=false
    if _env_key_is_sensitive "$key"; then
        sensitive=true
    fi
    val="$(_env_parse_env_value "$raw" "$sensitive")"
    printf "%s" "$val"
}
