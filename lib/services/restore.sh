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
    local target_arg="${ARGS[target]:-${ARGS[bundle_target]:-}}"
    local target="${target_arg:-${INM_INSTALLATION_PATH:-${INM_BASE_DIRECTORY%/}/${INM_INSTALLATION_DIRECTORY#/}}}"
    local target_was_explicit=false
    [[ -n "$target_arg" ]] && target_was_explicit=true
    local prebackup="${ARGS[pre_backup]:-${ARGS[pre-backup]:-true}}"
    local purge="${ARGS[purge_db]:-${ARGS[purge]:-true}}"
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
    if [[ -d "$bundle" ]]; then
        log info "[RESTORE] Using bundle directory: $bundle"
        cp -a "$bundle"/. "$tmpdir"/ || { log err "[RESTORE] Failed to stage bundle directory."; return 1; }
    else
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
    fi

    # Determine part files (either from extraction or directly if non-bundle)
    local db_part storage_part uploads_part app_part extra_part bundle_dir
    db_part=$(find "$tmpdir" -maxdepth 2 -type f -name "*_db.sql" | head -n1)
    storage_part=$(find "$tmpdir" -maxdepth 2 -type f \\( -name "*_storage.tar.gz" -o -name "*_storage.zip" \\) | head -n1)
    uploads_part=$(find "$tmpdir" -maxdepth 2 -type f \\( -name "*_uploads.tar.gz" -o -name "*_uploads.zip" \\) | head -n1)
    app_part=$(find "$tmpdir" -maxdepth 2 -type f \\( -name "*_app.tar.gz" -o -name "*_app.zip" \\) | head -n1)
    extra_part=$(find "$tmpdir" -maxdepth 2 -type f \\( -name "*_extra.tar.gz" -o -name "*_extra.zip" \\) | head -n1)
    # If no parts but a single dir (default full bundle), treat it as app root
    if [[ -z "$app_part" && -z "$storage_part" && -z "$uploads_part" && -z "$db_part" ]]; then
        local dirs_found=()
        while IFS= read -r d; do dirs_found+=("$d"); done < <(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d)
        if [[ ${#dirs_found[@]} -eq 1 ]]; then
            bundle_dir="${dirs_found[0]}"
            log info "[RESTORE] Detected single-folder bundle: $bundle_dir"
        fi
    fi

    [[ -n "$db_part" ]] && extracted_parts+=("$db_part")
    [[ -n "$storage_part" ]] && extracted_parts+=("$storage_part")
    [[ -n "$uploads_part" ]] && extracted_parts+=("$uploads_part")
    [[ -n "$app_part" ]] && extracted_parts+=("$app_part")
    [[ -n "$extra_part" ]] && extracted_parts+=("$extra_part")

    if [[ ${#extracted_parts[@]} -eq 0 && -z "$bundle_dir" ]]; then
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
    if [[ "$include_app" == true ]]; then
        if [[ -n "$app_part" ]]; then
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would extract app archive -> $target"
            else
                log info "[RESTORE] Extracting app archive -> $target"
                tar -xzf "$app_part" -C "$target" 2>/dev/null || unzip -q "$app_part" -d "$target" 2>/dev/null
            fi
        elif [[ -n "$bundle_dir" ]]; then
            if [[ "$target_was_explicit" == false ]]; then
                local suggested_target="$target"
                # If config produced an empty/relative path, ask for it explicitly
                if [[ -z "$suggested_target" || "$suggested_target" == "/" ]]; then
                    log warn "[RESTORE] No valid target from config. Please enter application directory."
                    read -r -p "Destination for app files [$suggested_target]: " _new_target
                    suggested_target="${_new_target:-$suggested_target}"
                else
                    log info "[RESTORE] Bundle app dir: $(basename "$bundle_dir")"
                    log info "[RESTORE] Destination from config (.env.inmanage): $suggested_target"
                    read -r -p "Destination for app files (press Enter to accept): " _new_target
                    [[ -n "$_new_target" ]] && suggested_target="$_new_target"
                fi
                target="$suggested_target"
            fi
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would copy bundled app dir -> $target"
            else
                log info "[RESTORE] Copying bundled app dir -> $target"
                mkdir -p "$target"
                rsync -a "$bundle_dir"/ "$target"/ || { log err "[RESTORE] Failed to copy app directory."; return 1; }
            fi
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
            import_database --file="$db_part" --force="$force" --pre-backup="$prebackup" --purge_before_import="$purge"
        fi
    fi

    # Post-restore integrity notes
    local version_file="${target%/}/VERSION.txt"
    if [[ -f "$version_file" ]]; then
        local restored_ver
        restored_ver="$(head -n1 "$version_file" | tr -d '[:space:]')"
        log ok "[RESTORE] Active app version: ${restored_ver:-unknown}"
        if declare -F get_latest_version >/dev/null 2>&1; then
            local latest_ver
            latest_ver="$(get_latest_version 2>/dev/null)"
            if [[ -n "$latest_ver" && "$restored_ver" != "$latest_ver" ]]; then
                log info "[RESTORE] Newer version available: $latest_ver. Run 'inmanage core update' to upgrade."
            fi
        else
            log info "[RESTORE] Hint: run 'inmanage core update' to check for newer releases."
        fi
    else
        log warn "[RESTORE] VERSION.txt missing in $target; unable to report restored version."
    fi

    log ok "[RESTORE] Restore flow completed${simulate:+ (dry-run)}."
}
