#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_ENV_LOADED:-} ]] && return
__SERVICE_ENV_LOADED=1

# shellcheck source=../helpers/env_parse.sh
# shellcheck disable=SC1090,SC1091
if [[ -f "${LIB_DIR}/helpers/env_parse.sh" ]]; then
    source "${LIB_DIR}/helpers/env_parse.sh"
else
    log err "[ENV] Missing env parse helper: ${LIB_DIR}/helpers/env_parse.sh"
fi

# ---------------------------------------------------------------------
# resolve_env_file()
# Resolve the env file path for app or CLI targets.
# Consumes: args: target; env: INM_ENV_FILE, INM_SELF_ENV_FILE; deps: expand_placeholders.
# Computes: validated env file path.
# Returns: prints path or non-zero on failure.
# ---------------------------------------------------------------------
resolve_env_file() {
    local target="${1:-app}"
    local path=""
    case "$target" in
        app)
            path="${INM_ENV_FILE:-}"
            # shellcheck disable=SC2016
        if [[ "$path" == *'${'* ]]; then
            path="$(expand_placeholders "$path")"
        fi
            ;;
        cli)
            path="${INM_SELF_ENV_FILE:-}"
            ;;
        *)
            log err "[ENV] Unknown env target: $target (use app|cli)"
            return 1
            ;;
    esac
    if [[ -z "$path" ]]; then
        log err "[ENV] No env file configured for target: $target"
        return 1
    fi
    if [[ ! -f "$path" ]]; then
        log err "[ENV] Env file not found: $path"
        return 1
    fi
    printf "%s" "$path"
}

# ---------------------------------------------------------------------
# _env_owner_for()
# Determine the owner to use for an env file.
# Consumes: args: env_file; env: INM_ENFORCED_USER; deps: _fs_get_owner.
# Computes: owner username.
# Returns: prints owner name.
# ---------------------------------------------------------------------
_env_owner_for() {
    local env_file="$1"
    local og owner
    og="$(_fs_get_owner "$env_file")"
    owner="${og%%:*}"
    if [[ -z "$owner" || "$owner" == "$og" ]]; then
        owner="${INM_ENFORCED_USER:-}"
    fi
    if [[ -z "$owner" ]]; then
        owner="$(whoami 2>/dev/null || true)"
    fi
    printf "%s" "$owner"
}

# ---------------------------------------------------------------------
# _env_owner_for_path()
# Determine the owner for a target path (file or parent).
# Consumes: args: path; env: INM_ENFORCED_USER; deps: _fs_get_owner.
# Computes: owner username.
# Returns: prints owner name.
# ---------------------------------------------------------------------
_env_owner_for_path() {
    local path="$1"
    local owner=""
    local og=""
    if [ -e "$path" ]; then
        og="$(_fs_get_owner "$path")"
    else
        og="$(_fs_get_owner "$(dirname "$path")")"
    fi
    owner="${og%%:*}"
    if [[ -z "$owner" || "$owner" == "$og" ]]; then
        owner="${INM_ENFORCED_USER:-}"
    fi
    if [[ -z "$owner" ]]; then
        owner="$(whoami 2>/dev/null || true)"
    fi
    printf "%s" "$owner"
}

# ---------------------------------------------------------------------
# _env_owner_group_for()
# Determine owner:group for an env file.
# Consumes: args: env_file, owner; deps: _fs_get_owner, id.
# Computes: owner:group string.
# Returns: prints owner:group.
# ---------------------------------------------------------------------
_env_owner_group_for() {
    local env_file="$1"
    local owner="${2:-}"
    local og=""
    og="$(_fs_get_owner "$env_file")"
    if [[ -n "$og" && "$og" == *:* ]]; then
        printf "%s" "$og"
        return 0
    fi
    if [[ -z "$owner" ]]; then
        owner="$(whoami 2>/dev/null || true)"
    fi
    local group
    group="$(id -gn "$owner" 2>/dev/null || true)"
    [[ -z "$group" ]] && group="$owner"
    printf "%s:%s" "$owner" "$group"
}

# ---------------------------------------------------------------------
# _env_owner_group_for_path()
# Determine owner:group for a target path (file or parent).
# Consumes: args: path, owner; deps: _fs_get_owner, id.
# Computes: owner:group string.
# Returns: prints owner:group.
# ---------------------------------------------------------------------
_env_owner_group_for_path() {
    local path="$1"
    local owner="${2:-}"
    local og=""
    if [ -e "$path" ]; then
        og="$(_fs_get_owner "$path")"
    else
        og="$(_fs_get_owner "$(dirname "$path")")"
    fi
    if [[ -n "$og" && "$og" == *:* ]]; then
        printf "%s" "$og"
        return 0
    fi
    if [[ -z "$owner" ]]; then
        owner="$(whoami 2>/dev/null || true)"
    fi
    local group
    group="$(id -gn "$owner" 2>/dev/null || true)"
    [[ -z "$group" ]] && group="$owner"
    printf "%s:%s" "$owner" "$group"
}

# ---------------------------------------------------------------------
# _env_access_mode()
# Decide how to access an env file (direct or sudo).
# Consumes: args: env_file, mode, owner; env: DRY_RUN; deps: prompt_confirm.
# Computes: access mode string.
# Returns: prints access mode or non-zero on failure.
# ---------------------------------------------------------------------
_env_access_mode() {
    local env_file="$1"
    local mode="${2:-read}"
    local owner="${3:-}"
    local need_write=false
    if [[ "$mode" == "write" ]]; then
        need_write=true
    fi
    local dir
    dir="$(dirname "$env_file")"
    if [[ ! -e "$env_file" && "$need_write" == true && -d "$dir" && -w "$dir" ]]; then
        echo "direct"
        return 0
    fi
    if [[ -r "$env_file" && ( "$need_write" == false || ( -w "$env_file" && -w "$dir" ) ) ]]; then
        echo "direct"
        return 0
    fi
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        echo "direct"
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        log err "[ENV] ${env_file} not ${mode}able and sudo is unavailable."
        return 1
    fi
    if sudo -n true 2>/dev/null; then
        if [[ "$need_write" == true && -n "$owner" ]]; then
            if sudo -u "$owner" test -w "$env_file" 2>/dev/null && sudo -u "$owner" test -w "$dir" 2>/dev/null; then
                echo "sudo"
            else
                echo "sudo-root"
            fi
            return 0
        fi
        echo "sudo"
        return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        log err "[ENV] ${env_file} not ${mode}able and no TTY for sudo prompt."
        return 1
    fi
    if prompt_confirm "ENV_SUDO" "no" "Env file not ${mode}able (${env_file}). Use sudo to proceed? [y/N]" false 60; then
        if [[ "$need_write" == true && -n "$owner" ]]; then
            if sudo -u "$owner" test -w "$env_file" 2>/dev/null && sudo -u "$owner" test -w "$dir" 2>/dev/null; then
                echo "sudo"
            else
                echo "sudo-root"
            fi
            return 0
        fi
        echo "sudo"
        return 0
    fi
    log err "[ENV] Insufficient permissions for ${env_file} (run as owner or with sudo)."
    return 1
}

# ---------------------------------------------------------------------
# _env_run()
# Run a command with the computed access mode.
# Consumes: args: access, owner, cmd...; deps: sudo.
# Computes: command execution.
# Returns: command exit code.
# ---------------------------------------------------------------------
_env_run() {
    local access="$1"
    local owner="$2"
    shift 2
    if [[ "$access" == "sudo-root" ]]; then
        sudo -- "$@"
    elif [[ "$access" == "sudo" ]]; then
        sudo -u "$owner" -- "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------
# _env_run_shell()
# Run a shell command with env vars using access mode.
# Consumes: args: access, owner, cmd, env pairs; deps: sudo.
# Computes: command execution via bash -c.
# Returns: command exit code.
# ---------------------------------------------------------------------
_env_run_shell() {
    local access="$1"
    local owner="$2"
    local cmd="$3"
    shift 3
    if [[ "$access" == "sudo-root" ]]; then
        sudo -- env "$@" bash -c "$cmd"
    elif [[ "$access" == "sudo" ]]; then
        sudo -u "$owner" -- env "$@" bash -c "$cmd"
    else
        env "$@" bash -c "$cmd"
    fi
}

# ---------------------------------------------------------------------
# _env_replace_file()
# Replace the target env file with a temp file.
# Consumes: args: access, owner, env_file, tmp_file; deps: _env_owner_group_for/_env_run.
# Computes: atomic file replacement and ownership fix.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
_env_replace_file() {
    local access="$1"
    local owner="$2"
    local env_file="$3"
    local tmp_file="$4"
    local owner_group=""

    if [[ "$access" == "sudo-root" ]]; then
        owner_group="$(_env_owner_group_for "$env_file" "$owner")"
    fi
    if ! _env_run "$access" "$owner" mv "$tmp_file" "$env_file"; then
        _env_run "$access" "$owner" rm -f "$tmp_file" 2>/dev/null || true
        log err "[ENV] Failed to update $env_file"
        return 1
    fi
    if [[ -n "$owner_group" ]]; then
        _env_run "$access" "$owner" chown "$owner_group" "$env_file" 2>/dev/null || true
    fi
    return 0
}

# ---------------------------------------------------------------------
# env_user_ini_apply()
# Write a managed .user.ini into the public webroot.
# Consumes: args: target_path; env: INM_INSTALLATION_PATH; globals: NAMED_ARGS; deps: _env_access_mode.
# Computes: .user.ini file contents and placement.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
env_user_ini_apply() {
    local target_path="${1:-}"
    local webroot="${INM_INSTALLATION_PATH%/}/public"
    local filename="${NAMED_ARGS[user_ini_filename]:-${NAMED_ARGS[user_ini]:-.user.ini}}"
    if [[ -z "${INM_INSTALLATION_PATH:-}" ]]; then
        log err "[ENV] INM_INSTALLATION_PATH is not set. Run from a configured project."
        return 1
    fi
    if [[ ! -d "$webroot" ]]; then
        log err "[ENV] Webroot not found: $webroot (app not installed yet)"
        return 1
    fi
    if [[ -z "$target_path" ]]; then
        target_path="${webroot%/}/${filename}"
    elif [[ "$target_path" != /* ]]; then
        target_path="${webroot%/}/${target_path}"
    fi
    local owner access
    owner="$(_env_owner_for_path "$target_path")"
    access="$(_env_access_mode "$target_path" "write" "$owner")" || return 1

    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would write .user.ini to $target_path"
        return 0
    fi

    local tmp_file
    tmp_file="$(_env_run "$access" "$owner" mktemp)" || {
        log err "[ENV] Failed to create temp file for $target_path"
        return 1
    }

    cat > "$tmp_file" <<'EOF'
; Inmanage-managed .user.ini for Invoice Ninja
memory_limit = 512M
max_execution_time = 300
max_input_time = 300
post_max_size = 128M
upload_max_filesize = 128M
max_input_vars = 5000
display_errors = Off
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
EOF

    if [[ "$access" == "sudo-root" ]]; then
        local owner_group
        owner_group="$(_env_owner_group_for_path "$target_path" "$owner")"
        if ! _env_run "$access" "$owner" mv "$tmp_file" "$target_path"; then
            _env_run "$access" "$owner" rm -f "$tmp_file" 2>/dev/null || true
            log err "[ENV] Failed to update $target_path"
            return 1
        fi
        _env_run "$access" "$owner" chown "$owner_group" "$target_path" 2>/dev/null || true
    else
        if ! mv "$tmp_file" "$target_path"; then
            rm -f "$tmp_file" 2>/dev/null || true
            log err "[ENV] Failed to update $target_path"
            return 1
        fi
    fi

    log ok "[ENV] Wrote .user.ini to $target_path"
}

# ---------------------------------------------------------------------
# env_show()
# Print the contents of the selected env file.
# Consumes: args: target; deps: resolve_env_file/_env_access_mode/_env_run.
# Computes: file output.
# Returns: command exit code.
# ---------------------------------------------------------------------
env_show() {
    local target="${1:-app}"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    local access owner
    owner="$(_env_owner_for "$env_file")"
    access="$(_env_access_mode "$env_file" "read" "$owner")" || return 1
    log debug "[ENV] Showing env from $env_file"
    _env_run "$access" "$owner" cat "$env_file"
}

# ---------------------------------------------------------------------
# env_get()
# Get a single key from app or CLI env file.
# Consumes: args: target, key; deps: resolve_env_file/_env_access_mode/_env_run/_env_parse_env_value.
# Computes: value extraction.
# Returns: prints value; 0 even if missing (warns).
# ---------------------------------------------------------------------
env_get() {
    local target="app" key
    # allow: env get app KEY
    if [[ "$1" == "app" || "$1" == "cli" ]]; then
        target="$1"; shift
    fi
    key="$1"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    local access owner
    owner="$(_env_owner_for "$env_file")"
    access="$(_env_access_mode "$env_file" "read" "$owner")" || return 1
    if [[ -z "$key" ]]; then
        log err "[ENV] Missing key. Usage: env get KEY"
        return 1
    fi
    if ! _env_key_valid "$key"; then
        log err "[ENV] Invalid key: $key"
        return 1
    fi
    local line
    line=$(_env_run "$access" "$owner" cat "$env_file" | grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" | tail -n1)
    if [[ -z "$line" ]]; then
        log warn "[ENV] Key not found: $key"
        return 0
    fi
    local raw val
    raw="${line#*=}"
    local sensitive=false
    if _env_key_is_sensitive "$key"; then
        sensitive=true
    fi
    val="$(_env_parse_env_value "$raw" "$sensitive")"
    echo "$val"
}

# ---------------------------------------------------------------------
# env_unset()
# Remove a key from app or CLI env file.
# Consumes: args: target, key; deps: resolve_env_file/_env_access_mode/_env_run/_env_replace_file.
# Computes: updated env file content.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
env_unset() {
    local target="app" key
    if [[ "$1" == "app" || "$1" == "cli" ]]; then
        target="$1"; shift
    fi
    key="$1"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    local access owner
    owner="$(_env_owner_for "$env_file")"
    access="$(_env_access_mode "$env_file" "write" "$owner")" || return 1
    if [[ -z "$key" ]]; then
        log err "[ENV] Missing key. Usage: env unset KEY"
        return 1
    fi
    if ! _env_key_valid "$key"; then
        log err "[ENV] Invalid key: $key"
        return 1
    fi
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would remove $key from $env_file"
        return 0
    fi
    if grep -q -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$env_file"; then
        local cmd tmp_file
        tmp_file="$(_env_run "$access" "$owner" mktemp)" || {
            log err "[ENV] Failed to create temp file for $env_file"
            return 1
        }
        # shellcheck disable=SC2016
        cmd='grep -v -E "^[[:space:]]*(export[[:space:]]+)?${KEY}[[:space:]]*=" "$ENV_FILE" > "$TMP" 2>/dev/null || true'
        _env_run_shell "$access" "$owner" "$cmd" KEY="$key" ENV_FILE="$env_file" TMP="$tmp_file" || return 1
        _env_replace_file "$access" "$owner" "$env_file" "$tmp_file" || return 1
        if [[ "$target" == "app" && -n "${INM_ENV_MODE:-}" ]]; then
            _env_run "$access" "$owner" chmod "${INM_ENV_MODE}" "$env_file" 2>/dev/null || true
        fi
        log ok "[ENV] Removed $key from $env_file"
    else
        log warn "[ENV] Key not found: $key"
    fi
}

# ---------------------------------------------------------------------
# _env_escape_value()
# Escape a value for inclusion in env files.
# Consumes: args: value, allow_placeholders.
# Computes: escaped value string.
# Returns: prints escaped value.
# ---------------------------------------------------------------------
_env_escape_value() {
    local value="$1"
    local allow_placeholders="${2:-false}"
    local out="$value"
    if [[ "$allow_placeholders" == true ]]; then
        out="${out//\\\$\{/\$\{}"
    fi
    out="${out//\\/\\\\}"
    out="${out//\"/\\\"}"
    out="${out//\$/\\\$}"
    out="${out//\`/\\\`}"
    printf "%s" "$out"
}

# ---------------------------------------------------------------------
# _env_key_valid()
# Validate an env key name.
# Consumes: args: key.
# Computes: regex match.
# Returns: 0 if valid, 1 if invalid.
# ---------------------------------------------------------------------
_env_key_valid() {
    local key="$1"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# ---------------------------------------------------------------------
# env_set()
# Set or update a key in app or CLI env file.
# Consumes: args: target, key=value; deps: resolve_env_file/_env_access_mode/_env_replace_file.
# Computes: updated env file content.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
env_set() {
    local target="app" pair
    if [[ "$1" == "app" || "$1" == "cli" ]]; then
        target="$1"; shift
    fi
    pair="$1"
    local env_file
    env_file="$(resolve_env_file "$target")" || return 1
    local access owner
    owner="$(_env_owner_for "$env_file")"
    access="$(_env_access_mode "$env_file" "write" "$owner")" || return 1
    if [[ -z "$pair" || "$pair" != *=* ]]; then
        log err "[ENV] Usage: env set [app|cli] KEY=VALUE"
        return 1
    fi
    local key="${pair%%=*}"
    local value="${pair#*=}"
    if ! _env_key_valid "$key"; then
        log err "[ENV] Invalid key: $key"
        return 1
    fi
    local allow_placeholders=false
    if [[ "$target" == "cli" ]]; then
        allow_placeholders=true
    fi
    local escaped_value
    escaped_value="$(_env_escape_value "$value" "$allow_placeholders")"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would set $key in $env_file"
        return 0
    fi
    local cmd tmp_file comment=""
    tmp_file="$(_env_run "$access" "$owner" mktemp)" || {
        log err "[ENV] Failed to create temp file for $env_file"
        return 1
    }
    local sensitive=false
    if _env_key_is_sensitive "$key"; then
        sensitive=true
    fi
    local file_content
    file_content="$(_env_run "$access" "$owner" cat "$env_file")"
    local -a lines=()
    local idx=0
    local last_idx=0
    local last_line=""
    while IFS= read -r line || [ -n "$line" ]; do
        idx=$((idx + 1))
        lines+=("$line")
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*= ]]; then
            last_idx=$idx
            last_line="$line"
        fi
    done <<< "$file_content"

    local new_line=""
    if [[ "$last_idx" -gt 0 ]]; then
        if [[ "$sensitive" == false ]]; then
            local raw
            raw="${last_line#*=}"
            comment="$(_env_extract_inline_comment "$raw")"
        fi
        if [[ "$last_line" =~ ^([[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*)(=[[:space:]]*)(.*)$ ]]; then
            local lhs="${BASH_REMATCH[1]}"
            local sep="${BASH_REMATCH[3]}"
            new_line="${lhs}${sep}\"${escaped_value}\"${comment}"
        else
            new_line="${key}=\"${escaped_value}\"${comment}"
        fi
        local -a updated=()
        idx=0
        for line in "${lines[@]}"; do
            idx=$((idx + 1))
            if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*= ]]; then
                if [[ "$idx" -eq "$last_idx" ]]; then
                    updated+=("$new_line")
                fi
                continue
            fi
            updated+=("$line")
        done
        lines=("${updated[@]}")
    else
        lines+=("${key}=\"${escaped_value}\"")
    fi

    local output=""
    for line in "${lines[@]}"; do
        output+="${line}"$'\n'
    done
    # shellcheck disable=SC2016
    cmd='printf "%s" "$CONTENT" > "$TMP"'
    _env_run_shell "$access" "$owner" "$cmd" CONTENT="$output" TMP="$tmp_file" || return 1
    _env_replace_file "$access" "$owner" "$env_file" "$tmp_file" || return 1
    if [[ "$target" == "app" && -n "${INM_ENV_MODE:-}" ]]; then
        _env_run "$access" "$owner" chmod "${INM_ENV_MODE}" "$env_file" 2>/dev/null || true
    fi
    log ok "[ENV] Set $key in $env_file"
}

# ---------------------------------------------------------------------
# env_instance_id_hash()
# Stable instance hash fallback (base+env).
# Consumes: args: base, env.
# Computes: instance id string.
# Returns: prints instance id.
# ---------------------------------------------------------------------
env_instance_id_hash() {
    local base="${1%/}"
    local env="${2%/}"
    local seed="${base}|${env}"
    local id=""
    if command -v cksum >/dev/null 2>&1; then
        id="$(printf "%s" "$seed" | cksum | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
        id="$(printf "%s" "$seed" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        id="$(printf "%s" "$seed" | shasum -a 256 | awk '{print $1}')"
    elif command -v sha256 >/dev/null 2>&1; then
        id="$(printf "%s" "$seed" | sha256 -q 2>/dev/null)"
    else
        id="$(printf "%s" "$seed" | tr -cd '[:alnum:]' | cut -c1-16)"
    fi
    if [[ -z "$id" ]]; then
        id="unknown"
    fi
    printf "inm-%s" "$id"
}

# ---------------------------------------------------------------------
# env_resolve_instance_id()
# Ensure a stable instance id exists in CLI config.
# Consumes: args: base, env; env: INM_INSTANCE_ID, INM_SELF_ENV_FILE; deps: env_set.
# Computes: instance id string; may persist to CLI config.
# Returns: prints instance id.
# ---------------------------------------------------------------------
env_resolve_instance_id() {
    local base="${1%/}"
    local env="${2%/}"
    local existing="${INM_INSTANCE_ID:-}"
    if [[ -n "$existing" ]]; then
        printf "%s" "$existing"
        return 0
    fi
    local generated=""
    if command -v uuidgen >/dev/null 2>&1; then
        generated="inm-$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    elif command -v openssl >/dev/null 2>&1; then
        generated="inm-$(openssl rand -hex 16 2>/dev/null)"
    fi
    if [[ -z "$generated" ]]; then
        generated="$(env_instance_id_hash "$base" "$env")"
    fi
    export INM_INSTANCE_ID="$generated"
    if [[ -n "${INM_SELF_ENV_FILE:-}" && -f "${INM_SELF_ENV_FILE}" ]]; then
        env_set cli "INM_INSTANCE_ID=${generated}" >/dev/null 2>&1 || true
    fi
    printf "%s" "$generated"
}
