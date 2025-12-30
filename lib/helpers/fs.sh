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
    local ok_level="${INM_SMO_LOG_LEVEL:-ok}"

    case "$ok_level" in
        ok|info|debug) ;;
        *) ok_level="ok" ;;
    esac

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
                log "$ok_level" "[SMO] Moved file $src to $dst"
                return 0
            fi
        else
            if cp -a "$src" "$dst"; then
                log "$ok_level" "[SMO] Copied file $src to $dst"
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
            log "$ok_level" "[SMO] Moved $src to $dst"
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
        safe_rm_rf "$src" "$(dirname "$src")" || log warn "[SMO] Failed to remove source $src after copy"
    fi

    log "$ok_level" "[SMO] Copied $src to $dst"
    return 0
}

# ---------------------------------------------------------------------
# safe_rm_rf()
# Removes a path only if it is within allowed roots.
# ---------------------------------------------------------------------
safe_rm_rf() {
    local target="$1"
    shift || true
    local roots=("$@")
    if [[ -z "$target" ]]; then
        log err "[FS] Refusing to remove empty path."
        return 1
    fi
    local resolved
    resolved="$(realpath "$target" 2>/dev/null || echo "$target")"
    if [[ "$resolved" != /* ]]; then
        local parent base parent_abs
        parent="$(dirname "$target")"
        base="$(basename "$target")"
        parent_abs="$(cd "$parent" 2>/dev/null && pwd)"
        if [[ -n "$parent_abs" ]]; then
            resolved="${parent_abs%/}/$base"
        fi
    fi
    if [[ -z "$resolved" || "$resolved" == "/" || "$resolved" == "." || "$resolved" == ".." ]]; then
        log err "[FS] Refusing to remove unsafe path: ${target}"
        return 1
    fi
    if [[ ${#roots[@]} -eq 0 ]]; then
        log err "[FS] Refusing to remove without allowed roots: $resolved"
        return 1
    fi
    local ok=false
    local root root_resolved root_prefix
    for root in "${roots[@]}"; do
        [[ -z "$root" ]] && continue
        root_resolved="$(realpath "$root" 2>/dev/null || echo "$root")"
        [[ -z "$root_resolved" ]] && continue
        root_prefix="$root_resolved"
        [[ "$root_prefix" != */ ]] && root_prefix="${root_prefix}/"
        if [[ "$resolved" == "$root_resolved" || "$resolved" == "$root_prefix"* ]]; then
            ok=true
            break
        fi
    done
    if [[ "$ok" != true ]]; then
        log err "[FS] Refusing to remove outside allowed roots: $resolved"
        return 1
    fi
    rm -rf -- "$target"
}

# ---------------------------------------------------------------------
# tar_validate_archive()
# Ensures no absolute paths, traversal, or links are present.
# ---------------------------------------------------------------------
tar_validate_archive() {
    local archive="$1"
    if [[ -z "$archive" ]]; then
        log err "[TAR] Archive path missing."
        return 1
    fi
    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        log err "[TAR] Cannot list archive: $archive"
        return 1
    fi

    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if [[ "$entry" == /* ]]; then
            log err "[TAR] Archive contains absolute path: $entry"
            return 1
        fi
        if [[ "$entry" == ".." || "$entry" == */.. || "$entry" == *"/../"* ]]; then
            log err "[TAR] Archive contains path traversal: $entry"
            return 1
        fi
    done < <(tar -tzf "$archive")

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local type="${line:0:1}"
        if [[ "$type" == "l" || "$type" == "h" ]]; then
            log err "[TAR] Archive contains link entry: $line"
            return 1
        fi
    done < <(tar -tvf "$archive")

    return 0
}

# ---------------------------------------------------------------------
# tar_safe_extract()
# Validates then extracts with safe flags.
# ---------------------------------------------------------------------
tar_safe_extract() {
    local archive="$1"
    local dest="$2"
    if ! tar_validate_archive "$archive"; then
        return 1
    fi
    local flags=()
    if [[ -n "${INM_TAR_EXTRACT_FLAGS:-}" ]]; then
        read -r -a flags <<< "$INM_TAR_EXTRACT_FLAGS"
    fi
    if ! tar -xzf "$archive" -C "$dest" "${flags[@]}"; then
        log err "[TAR] Failed to extract archive: $archive"
        return 1
    fi
}

# ---------------------------------------------------------------------
# zip_validate_archive()
# Ensures no absolute paths or traversal entries are present.
# ---------------------------------------------------------------------
zip_validate_archive() {
    local archive="$1"
    if [[ -z "$archive" ]]; then
        log err "[ZIP] Archive path missing."
        return 1
    fi
    local entries_cmd=(unzip -Z1 "$archive")
    if ! "${entries_cmd[@]}" >/dev/null 2>&1; then
        if command -v zipinfo >/dev/null 2>&1; then
            entries_cmd=(zipinfo -1 "$archive")
        else
            log err "[ZIP] No tool available to list archive entries."
            return 1
        fi
    fi
    if ! "${entries_cmd[@]}" >/dev/null 2>&1; then
        log err "[ZIP] Cannot list archive entries: $archive"
        return 1
    fi

    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        entry="${entry//\\//}"
        if [[ "$entry" == /* || "$entry" =~ ^[A-Za-z]:/ ]]; then
            log err "[ZIP] Archive contains absolute path: $entry"
            return 1
        fi
        if [[ "$entry" == ".." || "$entry" == */.. || "$entry" == *"/../"* ]]; then
            log err "[ZIP] Archive contains path traversal: $entry"
            return 1
        fi
    done < <("${entries_cmd[@]}")

    return 0
}

# ---------------------------------------------------------------------
# zip_safe_extract()
# Validates then extracts with safe defaults.
# ---------------------------------------------------------------------
zip_safe_extract() {
    local archive="$1"
    local dest="$2"
    if ! zip_validate_archive "$archive"; then
        return 1
    fi
    if ! unzip -q "$archive" -d "$dest"; then
        log err "[ZIP] Failed to extract archive: $archive"
        return 1
    fi
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
    local group="${INM_ENFORCED_GROUP:-${ENFORCED_GROUP:-}}"
    if [[ -z "$owner" ]]; then
        log debug "[EU] No enforced user configured; skipping chown."
        return 0
    fi
    if [[ -z "$group" ]]; then
        group="$(id -gn "$owner" 2>/dev/null || true)"
        [[ -z "$group" ]] && group="$owner"
    fi
    local expected="${owner}:${group}"
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            local resolved
            resolved="$(realpath "$path" 2>/dev/null || echo "$path")"
            if [[ -z "$resolved" || "$resolved" == "/" ]]; then
                log warn "[EU] Refusing to chown unsafe path: ${path}"
                continue
            fi
            local current
            current="$(_fs_get_owner "$path")"
            if [[ "$current" == "$expected" ]]; then
                log debug "[EU] Ownership already $current for $path"
                continue
            fi
            if ! chown -R "$expected" "$path" 2>/dev/null; then
                log warn "[EU] chown failed for $path (wanted $expected)"
            fi
        fi
    done
}

# ---------------------------------------------------------------------
# enforce_dir_permissions()
# Applies chmod to directories only (recursively) if paths exist.
# ---------------------------------------------------------------------
enforce_dir_permissions() {
    local mode="${1:-}"
    shift || true
    local paths=("$@")
    if [[ -z "$mode" || ${#paths[@]} -eq 0 ]]; then
        log debug "[EPD] Mode or paths missing; skipping dir chmod."
        return 0
    fi
    for path in "${paths[@]}"; do
        if [ -d "$path" ]; then
            if ! find "$path" -type d -exec chmod "$mode" {} + 2>/dev/null; then
                log warn "[EPD] chmod failed for $path (wanted $mode)"
            fi
        fi
    done
}

# ---------------------------------------------------------------------
# enforce_file_permissions()
# Applies chmod to files only (recursively) if paths exist.
# Skips files with any execute bit set.
# ---------------------------------------------------------------------
enforce_file_permissions() {
    local mode="${1:-}"
    shift || true
    local paths=("$@")
    if [[ -z "$mode" || ${#paths[@]} -eq 0 ]]; then
        log debug "[EPF] Mode or paths missing; skipping file chmod."
        return 0
    fi
    for path in "${paths[@]}"; do
        if [ -d "$path" ]; then
            if ! find "$path" -type f ! -perm -111 -exec chmod "$mode" {} + 2>/dev/null; then
                log warn "[EPF] chmod failed for files in $path (wanted $mode)"
            fi
        elif [ -f "$path" ]; then
            if ! chmod "$mode" "$path" 2>/dev/null; then
                log warn "[EPF] chmod failed for $path (wanted $mode)"
            fi
        fi
    done
}

# ---------------------------------------------------------------------
# enforce_file_mode()
# Applies chmod to specific files only.
# ---------------------------------------------------------------------
enforce_file_mode() {
    local mode="${1:-}"
    shift || true
    local files=("$@")
    if [[ -z "$mode" || ${#files[@]} -eq 0 ]]; then
        log debug "[EPF] Mode or files missing; skipping file chmod."
        return 0
    fi
    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            local current_mode
            current_mode="$(_fs_get_mode "$file")"
            if [[ "$current_mode" == "$mode" ]]; then
                log debug "[EPF] Mode already $mode for $file"
                continue
            fi
            if ! chmod "$mode" "$file" 2>/dev/null; then
                log warn "[EPF] chmod failed for $file (wanted $mode)"
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
