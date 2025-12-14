#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_RESTORE_LOADED:-} ]] && return
__SERVICE_RESTORE_LOADED=1

# ---------------------------------------------------------------------
# run_restore()
# Restores from a bundled/full backup. If no file provided, offers the
# newest bundle in the backup directory for selection.
# Options (NAMED_ARGS):
#   --file=<path>          Bundle or part to restore from (tar.gz/zip)
#   --force=true           Overwrite existing app directory
#   --include-app=true     Restore app files if present (default: true)
#   --target=<path>        Override install path (defaults to INM_INSTALLATION_PATH)
# ---------------------------------------------------------------------
run_restore() {
    declare -A ARGS
    parse_named_args ARGS "$@"

    local bundle="${ARGS[file]:-${ARGS[bundle]:-}}"
    local force="${ARGS[force]:-${force_update:-false}}"
    local include_app="${ARGS[include_app]:-${ARGS[include-app]:-true}}"
    local target="${ARGS[target]:-${INM_INSTALLATION_PATH:-${INM_BASE_DIRECTORY%/}/${INM_INSTALLATION_DIRECTORY#/}}}"
    local simulate="${DRY_RUN:-false}"

    mkdir -p "$INM_BACKUP_DIRECTORY" 2>/dev/null || true

    if [[ -z "$bundle" ]]; then
        local candidates=()
        while IFS= read -r f; do
            candidates+=("$f")
        done < <(ls -1t "$INM_BACKUP_DIRECTORY"/*_full.* 2>/dev/null)

        if [[ ${#candidates[@]} -eq 0 ]]; then
            log err "[RESTORE] No bundle found. Provide --file=<bundle.tar.gz>."
            return 1
        fi

        bundle="$(select_from_candidates "Select a backup to restore" "${candidates[@]}")" || return 1
    fi

    if [[ ! -f "$bundle" ]]; then
        log err "[RESTORE] File not found: $bundle"
        return 1
    fi

    bundle="$(cd "$(dirname "$bundle")" && pwd)/$(basename "$bundle")"
    log info "[RESTORE] Using bundle: $bundle"
    log info "[RESTORE] Target app dir: $target"
    [[ "$simulate" == true ]] && log info "[DRY-RUN] Restore simulation only (no changes)."

    local tmpdir
    tmpdir="$(mktemp -d)"
    cleanup_tmp_restore() { rm -rf "$tmpdir"; }
    trap cleanup_tmp_restore EXIT

    local extracted_parts=()
    case "$bundle" in
        *.tar.gz|*.tgz)
            tar -xzf "$bundle" -C "$tmpdir" || { log err "[RESTORE] Failed to extract bundle."; return 1; }
            ;;
        *.zip)
            unzip -q "$bundle" -d "$tmpdir" || { log err "[RESTORE] Failed to extract bundle."; return 1; }
            ;;
        *)
            log err "[RESTORE] Unsupported bundle format: $bundle"
            return 1
            ;;
    esac

    # Determine part files (either from extraction or directly if non-bundle)
    local db_part storage_part uploads_part app_part extra_part
    db_part=$(find "$tmpdir" -maxdepth 1 -name "*_db.sql" | head -n1)
    storage_part=$(find "$tmpdir" -maxdepth 1 -name "*_storage.tar.gz" -o -name "*_storage.zip" | head -n1)
    uploads_part=$(find "$tmpdir" -maxdepth 1 -name "*_uploads.tar.gz" -o -name "*_uploads.zip" | head -n1)
    app_part=$(find "$tmpdir" -maxdepth 1 -name "*_app.tar.gz" -o -name "*_app.zip" | head -n1)
    extra_part=$(find "$tmpdir" -maxdepth 1 -name "*_extra.tar.gz" -o -name "*_extra.zip" | head -n1)

    [[ -n "$db_part" ]] && extracted_parts+=("$db_part")
    [[ -n "$storage_part" ]] && extracted_parts+=("$storage_part")
    [[ -n "$uploads_part" ]] && extracted_parts+=("$uploads_part")
    [[ -n "$app_part" ]] && extracted_parts+=("$app_part")
    [[ -n "$extra_part" ]] && extracted_parts+=("$extra_part")

    if [[ ${#extracted_parts[@]} -eq 0 ]]; then
        log err "[RESTORE] No recognizable parts found in bundle."
        return 1
    fi

    # Prepare target
    if [[ "$include_app" == true && -d "$target" && "$force" != true ]]; then
        log err "[RESTORE] Target $target exists. Use --force=true to overwrite."
        return 1
    fi
    if [[ "$include_app" == true && -d "$target" && "$force" == true && "$simulate" != true ]]; then
        log warn "[RESTORE] Removing existing target due to --force: $target"
        rm -rf "$target"
    fi
    [[ "$simulate" != true ]] && mkdir -p "$target"

    # Restore app files (if present and requested)
    if [[ "$include_app" == true && -n "$app_part" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would extract app archive -> $target"
        else
            log info "[RESTORE] Extracting app archive -> $target"
            tar -xzf "$app_part" -C "$target" 2>/dev/null || unzip -q "$app_part" -d "$target" 2>/dev/null
        fi
    fi

    # Restore storage/uploads
    if [[ -n "$storage_part" ]]; then
        local storage_dest="$target"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore storage -> $storage_dest"
        else
            log info "[RESTORE] Restoring storage ..."
            tar -xzf "$storage_part" -C "$storage_dest" 2>/dev/null || unzip -q "$storage_part" -d "$storage_dest" 2>/dev/null
        fi
    fi

    if [[ -n "$uploads_part" ]]; then
        local uploads_dest="$target/public"
        [[ "$simulate" != true ]] && mkdir -p "$uploads_dest"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore uploads -> $uploads_dest"
        else
            log info "[RESTORE] Restoring uploads ..."
            tar -xzf "$uploads_part" -C "$uploads_dest" 2>/dev/null || unzip -q "$uploads_part" -d "$uploads_dest" 2>/dev/null
        fi
    fi

    if [[ -n "$extra_part" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore extra paths -> $target"
        else
            log info "[RESTORE] Restoring extra paths ..."
            tar -xzf "$extra_part" -C "$target" 2>/dev/null || unzip -q "$extra_part" -d "$target" 2>/dev/null
        fi
    fi

    # Restore DB last
    if [[ -n "$db_part" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would import database from $db_part"
        else
            log info "[RESTORE] Importing database from $db_part"
            import_database --file="$db_part" --force="$force"
        fi
    fi

    log ok "[RESTORE] Restore flow completed${simulate:+ (dry-run)}."
}
