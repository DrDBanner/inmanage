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

    if [ "$mode" = "move" ] || [ "$mode" = "new" ]; then
        if mv "$src" "$dst"; then
            log ok "[SMO] Moved $src to $dst"
            return 0
        fi
        log warn "[SMO] mv failed, trying rsync copy..."
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
# enforce_ownership()
# Applies chown recursively to given paths if they exist.
# ---------------------------------------------------------------------
enforce_ownership() {
    local paths=("$@")
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            if ! chown -R "$ENFORCED_USER:$ENFORCED_USER" "$path" 2>/dev/null; then
                log warn "[EU] chown failed for $path"
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
