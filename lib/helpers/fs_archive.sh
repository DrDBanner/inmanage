#!/usr/bin/env bash

# ---------------------------------------------------------------------
# tar_validate_archive()
# Validate a tar.gz for unsafe entry paths.
# Consumes: args: archive; tools: tar.
# Computes: scans entries for absolute paths and traversal.
# Returns: 0 if safe, 1 if invalid/unreadable.
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

    local entry=""
    local path=""
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        path="$entry"
        while [[ "$path" == ./* ]]; do
            path="${path#./}"
        done
        path="${path%/}"
        [[ -z "$path" || "$path" == "." ]] && continue

        if [[ "$path" == /* || "$path" =~ ^[A-Za-z]:/ ]]; then
            log err "[TAR] Archive contains absolute path: $entry"
            return 1
        fi

        if [[ "$path" == ".." || "$path" == ../* || "$path" == */.. || "$path" == *"/../"* ]]; then
            log err "[TAR] Archive contains path traversal: $entry"
            return 1
        fi
    done < <(tar -tzf "$archive")

    return 0
}

# ---------------------------------------------------------------------
# tar_safe_extract()
# Validate then extract a tar.gz archive with optional flags.
# Consumes: args: archive, dest; env: INM_TAR_EXTRACT_FLAGS; tools: tar.
# Computes: safe validation then extraction.
# Returns: 0 on success, 1 on failure.
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
# tar_extract_fallback()
# Extract with safe validation if available, else direct tar.
# Consumes: args: archive, dest; deps: tar_safe_extract; tools: tar.
# Computes: extraction into dest.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
tar_extract_fallback() {
    local archive="$1"
    local dest="$2"
    tar_safe_extract "$archive" "$dest"
}

# ---------------------------------------------------------------------
# zip_validate_archive()
# Validate a zip archive for unsafe paths.
# Consumes: args: archive; tools: unzip or zipinfo.
# Computes: scans entries for absolute paths and traversal.
# Returns: 0 if safe, 1 if invalid/unreadable.
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
# Validate then extract a zip archive.
# Consumes: args: archive, dest; tools: unzip.
# Computes: safe validation then extraction.
# Returns: 0 on success, 1 on failure.
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
# zip_extract_fallback()
# Extract with safe validation if available, else direct unzip.
# Consumes: args: archive, dest; deps: zip_safe_extract; tools: unzip.
# Computes: extraction into dest.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
zip_extract_fallback() {
    local archive="$1"
    local dest="$2"
    zip_safe_extract "$archive" "$dest"
}
