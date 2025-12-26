#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__FS_HELPER_LOADED:-} ]] && return
__FS_HELPER_LOADED=1

# ---------------------------------------------------------------------
# safe_move_or_copy_and_clean()
#
# Moves or copies a directory to a destination. If move fails, falls back
# to rsync/copy, then cleans up the source when requested.
# ---------------------------------------------------------------------
safe_move_or_copy_and_clean() {
    local src="$1"
    local dst="$2"
    local mode="${3:-move}"      # move or copy

    if [ -z "$src" ] || [ -z "$dst" ]; then
        log err "[SMO] Source or destination missing."
        return 1
    fi
    if [ -f "$src" ]; then
        if [ -d "$dst" ] || [[ "$dst" == */ ]]; then
            log err "[SMO] Destination is a directory for file source: $dst"
            return 1
        fi
        if [ "$mode" = "move" ] || [ "$mode" = "new" ]; then
            if mv "$src" "$dst"; then
                log ok "[SMO] Moved file $src to $dst"
                return 0
            fi
        else
            if cp -a "$src" "$dst"; then
                log ok "[SMO] Copied file $src to $dst"
                return 0
            fi
        fi
        log err "[SMO] File move/copy failed: $src -> $dst"
        return 1
    fi
    if [ ! -d "$src" ]; then
        log err "[SMO] Source is not a directory: $src"
        return 1
    fi
    if [ -e "$dst" ] && [ ! -d "$dst" ]; then
        log err "[SMO] Destination exists but is not a directory: $dst"
        return 1
    fi

    if [ "$mode" = "move" ] || [ "$mode" = "new" ]; then
        if mv "$src" "$dst"; then
            log ok "[SMO] Moved $src to $dst"
            return 0
        fi
        log warn "[SMO] mv failed, trying rsync copy..."
    fi

    if [ ! -d "$dst" ]; then
        mkdir -p "$dst" || {
            log err "[SMO] Failed to create destination directory: $dst"
            return 1
        }
    fi
    rsync -a --delete "$src/" "$dst/" || {
        log err "[SMO] rsync failed from $src to $dst"
        return 1
    }

    if [ "$mode" = "move" ] || [ "$mode" = "new" ]; then
        rm -rf "$src" || log warn "[SMO] Failed to remove source $src after copy"
    fi

    log ok "[SMO] Copied $src to $dst"
    return 0
}

# ---------------------------------------------------------------------
# assert_file_path()
# Validates that a path is suitable for a file (not a directory).
# Does not require the file to exist.
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
# internal: best-effort owner/mode detection (portable)
_fs_get_owner() {
    local path="$1"
    local owner=""
    owner=$(stat -c '%U:%G' "$path" 2>/dev/null || stat -f '%Su:%Sg' "$path" 2>/dev/null || echo "")
    printf "%s" "$owner"
}

_fs_get_mode() {
    local path="$1"
    local mode=""
    mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Mp%Lp' "$path" 2>/dev/null || echo "")
    mode="${mode##0}" # drop leading zeros
    printf "%s" "$mode"
}

# enforce_ownership()
# Applies chown recursively to given paths if they exist.
# ---------------------------------------------------------------------
enforce_ownership() {
    local paths=("$@")
    local owner="${INM_ENFORCED_USER:-${ENFORCED_USER:-}}"
    if [[ -z "$owner" ]]; then
        log debug "[EU] No enforced user configured; skipping chown."
        return 0
    fi
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            local current
            current="$(_fs_get_owner "$path")"
            if [[ "$current" == "$owner:$owner" ]]; then
                log debug "[EU] Ownership already $current for $path"
                continue
            fi
            if ! chown -R "$owner:$owner" "$path" 2>/dev/null; then
                log warn "[EU] chown failed for $path (wanted $owner:$owner)"
            fi
        fi
    done
}

# ---------------------------------------------------------------------
# enforce_permissions()
# Applies chmod recursively if paths exist.
# ---------------------------------------------------------------------
enforce_permissions() {
    local mode="${1:-}"
    shift || true
    local paths=("$@")
    if [[ -z "$mode" || ${#paths[@]} -eq 0 ]]; then
        log debug "[EP] Mode or paths missing; skipping chmod."
        return 0
    fi
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            local current_mode
            current_mode="$(_fs_get_mode "$path")"
            if [[ "$current_mode" == "$mode" ]]; then
                log debug "[EP] Mode already $mode for $path"
                continue
            fi
            if ! chmod -R "$mode" "$path" 2>/dev/null; then
                log warn "[EP] chmod failed for $path (wanted $mode)"
            fi
        fi
    done
}

# ---------------------------------------------------------------------
# app_sanity_check()
# Performs basic integrity checks on an Invoice Ninja app directory.
# Logs missing critical pieces and returns non-zero if critical items
# are missing. Non-critical findings are logged as warnings.
# ---------------------------------------------------------------------
app_sanity_check() {
    local dir="$1"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        log err "[ASC] App directory not found: ${dir:-<unset>}"
        return 1
    fi

    local missing=()
    local warn=()

    [[ -f "${dir%/}/artisan" ]] || missing+=("artisan")
    [[ -f "${dir%/}/vendor/autoload.php" ]] || missing+=("vendor/autoload.php")
    [[ -f "${dir%/}/public/index.php" ]] || missing+=("public/index.php")
    [[ -f "${dir%/}/.env" ]] || missing+=(".env")
    [[ -d "${dir%/}/storage" ]] || missing+=("storage/")
    [[ -d "${dir%/}/public" ]] || missing+=("public/")
    [[ -d "${dir%/}/routes" ]] || warn+=("routes/")
    [[ -d "${dir%/}/resources/views" ]] || warn+=("resources/views/")
    [[ -d "${dir%/}/database" ]] || warn+=("database/")
    [[ -f "${dir%/}/public/.htaccess" ]] || warn+=("public/.htaccess")

    [[ -d "${dir%/}/bootstrap/cache" ]] || warn+=("bootstrap/cache/")
    [[ -f "${dir%/}/composer.json" ]] || warn+=("composer.json")
    [[ -f "${dir%/}/VERSION.txt" ]] || warn+=("VERSION.txt")

    if command -v du >/dev/null 2>&1; then
        local sz
        sz=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        [[ -n "$sz" ]] && log info "[ASC] App footprint: $sz at $dir"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log err "[ASC] Critical app items missing: ${missing[*]}"
        return 1
    fi

    if [[ ${#warn[@]} -gt 0 ]]; then
        log warn "[ASC] Non-critical items missing: ${warn[*]}"
    else
        log ok "[ASC] App structure looks complete."
    fi
    return 0
}

# ---------------------------------------------------------------------
# ensure_trailing_slash()
# Normalizes a path with a single trailing slash; keeps absolute/relative intact.
# ---------------------------------------------------------------------
ensure_trailing_slash() {
    local path="$1"
    [[ -z "$path" ]] && return 1
    # Strip existing trailing slashes and re-append one
    printf "%s/\n" "${path%/}"
}
