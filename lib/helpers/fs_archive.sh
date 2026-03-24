#!/usr/bin/env bash

# ---------------------------------------------------------------------
# tar_normalize_path()
# Normalize an archive-internal path without allowing traversal above root.
# Consumes: args: path.
# Computes: canonical relative path inside archive.
# Returns: normalized path on stdout, 0 on success, 1 on invalid path.
# ---------------------------------------------------------------------
tar_normalize_path() {
    local raw="$1"
    local path="${raw%/}"

    if [[ -z "$path" || "$path" == "." ]]; then
        printf ".\n"
        return 0
    fi
    if [[ "$path" == /* || "$path" =~ ^[A-Za-z]:/ ]]; then
        return 1
    fi

    local old_ifs="$IFS"
    local -a parts=()
    local -a normalized=()
    IFS='/'
    read -r -a parts <<< "$path"
    IFS="$old_ifs"

    local part
    for part in "${parts[@]}"; do
        case "$part" in
            ""|".")
                continue
                ;;
            "..")
                if [[ ${#normalized[@]} -eq 0 ]]; then
                    return 1
                fi
                unset 'normalized[${#normalized[@]}-1]'
                ;;
            *)
                normalized+=("$part")
                ;;
        esac
    done

    if [[ ${#normalized[@]} -eq 0 ]]; then
        printf ".\n"
        return 0
    fi

    local joined=""
    for part in "${normalized[@]}"; do
        joined+="${joined:+/}${part}"
    done
    printf "%s\n" "$joined"
}

# ---------------------------------------------------------------------
# tar_path_is_safe()
# Validate an archive entry path or hardlink target.
# Consumes: args: path.
# Computes: canonical form inside archive root.
# Returns: normalized path on stdout, 0 if safe, 1 otherwise.
# ---------------------------------------------------------------------
tar_path_is_safe() {
    local path="$1"
    local normalized=""

    if [[ -z "$path" ]]; then
        return 1
    fi
    normalized="$(tar_normalize_path "$path")" || return 1
    printf "%s\n" "$normalized"
}

# ---------------------------------------------------------------------
# tar_resolve_link_target()
# Resolve a symlink target against its parent path within the archive.
# Consumes: args: link_path, target.
# Computes: normalized target path inside archive root.
# Returns: normalized path on stdout, 0 if safe, 1 otherwise.
# ---------------------------------------------------------------------
tar_resolve_link_target() {
    local link_path="$1"
    local target="$2"

    [[ -z "$link_path" || -z "$target" ]] && return 1
    if [[ "$target" == /* || "$target" =~ ^[A-Za-z]:/ ]]; then
        return 1
    fi

    local base_dir=""
    if [[ "$link_path" == */* ]]; then
        base_dir="${link_path%/*}"
    fi

    local combined="$target"
    if [[ -n "$base_dir" ]]; then
        combined="${base_dir%/}/${target}"
    fi

    tar_normalize_path "$combined"
}

# ---------------------------------------------------------------------
# tar_find_entry_from_verbose_prefix()
# Match a verbose tar listing prefix back to a known archive entry.
# Consumes: args: prefix, entries...
# Computes: longest suffix match for the entry name.
# Returns: entry path on stdout, 0 if matched, 1 otherwise.
# ---------------------------------------------------------------------
tar_find_entry_from_verbose_prefix() {
    local prefix="$1"
    shift || true

    local candidate=""
    local best=""
    local best_len=0
    for candidate in "$@"; do
        [[ -z "$candidate" ]] && continue
        if [[ "$prefix" == *"$candidate" ]]; then
            if (( ${#candidate} > best_len )); then
                best="$candidate"
                best_len=${#candidate}
            fi
        fi
    done

    [[ -n "$best" ]] || return 1
    printf "%s\n" "$best"
}

# ---------------------------------------------------------------------
# tar_validate_archive()
# Validate a tar.gz for unsafe paths and link handling.
# Consumes: args: archive; tools: tar.
# Computes: scans entries for absolute paths, traversal, and unsafe links.
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

    local -a entries=()
    local -a normalized_entries=()
    local entry=""
    local normalized_entry=""
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        normalized_entry="$(tar_path_is_safe "$entry")" || {
            if [[ "$entry" == /* || "$entry" =~ ^[A-Za-z]:/ ]]; then
                log err "[TAR] Archive contains absolute path: $entry"
            else
                log err "[TAR] Archive contains path traversal: $entry"
            fi
            return 1
        }
        [[ "$normalized_entry" == "." ]] && continue
        entries+=("$entry")
        normalized_entries+=("$normalized_entry")
    done < <(tar -tzf "$archive")

    local -A link_paths=()
    local line=""
    local type=""
    local delimiter=""
    local prefix=""
    local link_target=""
    local link_path=""
    local resolved_target=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        type="${line:0:1}"
        [[ "$type" == "l" || "$type" == "h" ]] || continue

        delimiter=""
        if [[ "$type" == "l" && "$line" == *" -> "* ]]; then
            delimiter=" -> "
        elif [[ "$type" == "h" && "$line" == *" link to "* ]]; then
            delimiter=" link to "
        elif [[ "$line" == *" -> "* ]]; then
            delimiter=" -> "
        elif [[ "$line" == *" link to "* ]]; then
            delimiter=" link to "
        fi

        if [[ -z "$delimiter" ]]; then
            log err "[TAR] Could not parse archive link entry: $line"
            return 1
        fi

        prefix="${line%"$delimiter"*}"
        link_target="${line##*"$delimiter"}"
        link_path="$(tar_find_entry_from_verbose_prefix "$prefix" "${entries[@]}")" || {
            log err "[TAR] Could not resolve archive link path: $line"
            return 1
        }
        link_path="$(tar_path_is_safe "$link_path")" || {
            log err "[TAR] Archive contains unsafe link path: $line"
            return 1
        }

        if [[ "$type" == "l" || "$delimiter" == " -> " ]]; then
            resolved_target="$(tar_resolve_link_target "$link_path" "$link_target")" || {
                log err "[TAR] Archive contains unsafe symlink target: $line"
                return 1
            }
        else
            resolved_target="$(tar_path_is_safe "$link_target")" || {
                log err "[TAR] Archive contains unsafe hardlink target: $line"
                return 1
            }
        fi

        link_paths["$link_path"]="$resolved_target"
    done < <(tar -tvzf "$archive")

    local link_prefix=""
    local candidate_path=""
    local link_path_key=""
    for link_path_key in "${!link_paths[@]}"; do
        link_prefix="${link_path_key%/}/"
        for candidate_path in "${normalized_entries[@]}"; do
            if [[ "$candidate_path" != "$link_path_key" && "$candidate_path" == "$link_prefix"* ]]; then
                log err "[TAR] Archive contains path below link entry: ${candidate_path} (link: ${link_path_key})"
                return 1
            fi
        done
    done

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
