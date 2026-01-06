#!/usr/bin/env bash

# ---------------------------------------------------------------------
# expand_placeholders()
# Replace ${VAR} occurrences without eval.
# Consumes: args: input string; env: INM_ORIGINAL_HOME/HOME.
# Computes: placeholder-expanded string.
# Returns: string on stdout.
# ---------------------------------------------------------------------
expand_placeholders() {
    local input="$1"
    local output="$input"
    while [[ "$output" =~ (\$\{([^}]+)\}) ]]; do
        local full="${BASH_REMATCH[1]}"
        local var="${BASH_REMATCH[2]}"
        local val
        if [[ "$var" == "HOME" && -n "${INM_ORIGINAL_HOME:-}" ]]; then
            val="$INM_ORIGINAL_HOME"
        else
            val="${!var}"
        fi
        output="${output//$full/$val}"
    done
    printf "%s" "$output"
}

# ---------------------------------------------------------------------
# path_expand_no_eval()
# Expand ~ and ${VAR} without invoking eval.
# Consumes: args: path; env: INM_ORIGINAL_HOME/HOME.
# Computes: normalized path string.
# Returns: expanded path on stdout.
# ---------------------------------------------------------------------
path_expand_no_eval() {
    local p="$1"
    [[ -z "$p" ]] && { printf "%s" "$p"; return; }
    p="$(expand_placeholders "$p")"
    local home_base="${INM_ORIGINAL_HOME:-$HOME}"
    p="${p/#\~/$home_base}"
    p="${p//\$\{HOME\}/$home_base}"
    p="${p//\$HOME/$home_base}"
    printf "%s" "$p"
}

# ---------------------------------------------------------------------
# _fs_get_owner()
# Best-effort owner:group lookup for a path.
# Consumes: args: path; tools: stat.
# Computes: owner string.
# Returns: owner string (empty if unavailable).
# ---------------------------------------------------------------------
_fs_get_owner() {
    local path="$1"
    local owner=""
    owner=$(stat -c '%U:%G' "$path" 2>/dev/null || stat -f '%Su:%Sg' "$path" 2>/dev/null || echo "")
    printf "%s" "$owner"
}

# ---------------------------------------------------------------------
# _fs_get_mode()
# Best-effort octal mode lookup for a path.
# Consumes: args: path; tools: stat.
# Computes: mode string.
# Returns: mode string (empty if unavailable).
# ---------------------------------------------------------------------
_fs_get_mode() {
    local path="$1"
    local mode=""
    mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Mp%Lp' "$path" 2>/dev/null || echo "")
    mode="${mode##0}" # drop leading zeros
    printf "%s" "$mode"
}

# ---------------------------------------------------------------------
# assert_file_path()
# Validate that a path is a file target (not a dir).
# Consumes: args: path, label.
# Computes: basic sanity checks on path.
# Returns: 0 if valid, 1 if invalid.
# ---------------------------------------------------------------------
assert_file_path() {
    local path="$1"
    local label="${2:-Path}"

    if [[ -z "$path" ]]; then
        log err "[FS] ${label} is empty."
        return 1
    fi
    if [[ "$path" == */ ]]; then
        log err "[FS] ${label} ends with '/': $path"
        return 1
    fi
    if [[ -d "$path" ]]; then
        log err "[FS] ${label} resolves to a directory: $path"
        return 1
    fi
    local base
    base="$(basename "$path")"
    if [[ "$base" == "." || "$base" == ".." ]]; then
        log err "[FS] ${label} basename is invalid: $path"
        return 1
    fi
    local parent
    parent="$(dirname "$path")"
    if [[ -e "$parent" && ! -d "$parent" ]]; then
        log err "[FS] ${label} parent is not a directory: $parent"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# ensure_trailing_slash()
# Normalize a path with a single trailing slash.
# Consumes: args: path.
# Computes: normalized path string.
# Returns: normalized path or 1 if empty input.
# ---------------------------------------------------------------------
ensure_trailing_slash() {
    local path="$1"
    [[ -z "$path" ]] && return 1
    # Strip existing trailing slashes and re-append one
    printf "%s/\n" "${path%/}"
}

# ---------------------------------------------------------------------
# fs_path_inside_tree()
# Check if a path resolves inside a tree root.
# Consumes: args: tree_root, src; tools: realpath.
# Computes: boolean containment check.
# Returns: 0 if inside, 1 otherwise.
# ---------------------------------------------------------------------
fs_path_inside_tree() {
    local tree_root="$1"
    local src="$2"
    [[ ! -e "$src" || -L "$src" ]] && return 1
    local src_real
    src_real=$(realpath "$src" 2>/dev/null || echo "$src")
    [[ "$src_real" == "$tree_root"/* ]]
}

# ---------------------------------------------------------------------
# fs_resolve_relative_path()
# Resolve a relative path against a base directory.
# Consumes: args: base, p.
# Computes: absolute or joined path.
# Returns: resolved path on stdout.
# ---------------------------------------------------------------------
fs_resolve_relative_path() {
    local base="$1"
    local p="$2"
    if [[ "$p" == /* ]]; then
        printf "%s\n" "$p"
    else
        printf "%s/%s\n" "$base" "${p#/}"
    fi
}

# ---------------------------------------------------------------------
# fs_path_size()
# Human-readable size for a path.
# Consumes: args: path; tools: du.
# Computes: size string.
# Returns: size on stdout (empty if unavailable).
# ---------------------------------------------------------------------
fs_path_size() {
    local p="$1"
    if command -v du >/dev/null 2>&1; then
        du -sh "$p" 2>/dev/null | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------
# fs_path_size_kb()
# Size in kilobytes for a path.
# Consumes: args: path; tools: du.
# Computes: size in KB.
# Returns: size on stdout (empty if unavailable).
# ---------------------------------------------------------------------
fs_path_size_kb() {
    local p="$1"
    if command -v du >/dev/null 2>&1; then
        du -sk "$p" 2>/dev/null | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------
# fs_path_size_timeout()
# Size with optional timeout to avoid stalls.
# Consumes: args: path, timeout; tools: du, timeout (optional).
# Computes: size string.
# Returns: size on stdout, or non-zero on error/timeout.
# ---------------------------------------------------------------------
fs_path_size_timeout() {
    local p="$1"
    local timeout="$2"
    if [[ -z "$p" || ! -d "$p" ]]; then
        return 1
    fi
    if ! command -v du >/dev/null 2>&1; then
        return 1
    fi
    if [[ -n "$timeout" && "$timeout" =~ ^[0-9]+$ ]] && command -v timeout >/dev/null 2>&1; then
        local du_out du_rc=0
        local errexit_set=false
        [[ $- == *e* ]] && errexit_set=true
        set +e
        du_out=$(timeout "$timeout" du -sh "$p" 2>/dev/null)
        du_rc=$?
        $errexit_set && set -e
        if [[ "$du_rc" -eq 0 ]]; then
            printf "%s" "$(echo "$du_out" | awk '{print $1}')"
            return 0
        fi
        return "$du_rc"
    fi
    du -sh "$p" 2>/dev/null | awk '{print $1}'
}

# ---------------------------------------------------------------------
# fs_resolve_single_root_dir()
# If root contains a single subdir, return it; else return root.
# Consumes: args: root; tools: find.
# Computes: resolved root.
# Returns: resolved directory path on stdout.
# ---------------------------------------------------------------------
fs_resolve_single_root_dir() {
    local root="$1"
    local resolved="$root"
    mapfile -t top_entries < <(find "$root" -mindepth 1 -maxdepth 1 -print)
    if [[ ${#top_entries[@]} -eq 1 && -d "${top_entries[0]}" ]]; then
        resolved="${top_entries[0]}"
    fi
    printf "%s\n" "$resolved"
}
