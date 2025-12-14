#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_BACKUP_LOADED:-} ]] && return
__SERVICE_BACKUP_LOADED=1

# ---------------------------------------------------------------------
# run_backup()
# Creates backups (DB/storage/uploads) with bundling/compression.
# ---------------------------------------------------------------------
run_backup() {
    declare -A ARGS
    parse_named_args ARGS "$@"

    local compress="${ARGS[compress]:-tar.gz}"
    local bundle="${ARGS[bundle]:-true}"
    local name="${ARGS[name]:-$(date +%Y%m%d-%H%M)}"
    local include_app="${ARGS[include_app]:-${ARGS[include-app]:-false}}"
    local extra_paths_raw="${ARGS[extra_paths]:-${ARGS[extra]:-}}"

    local db="${ARGS[db]:-false}"
    local storage="${ARGS[storage]:-false}"
    local uploads="${ARGS[uploads]:-false}"
    local fullbackup="${ARGS[fullbackup]:-true}"
    local create_script="${ARGS[create_backup_script]:-false}"
    local script_target="${ARGS[script_path]:-backup_remote_job.sh}"

    if [[ "$create_script" == "true" ]]; then
        local root_dir
        root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        local template="$root_dir/templates/backup_remote_job.sh"

        if [[ ! -f "$template" ]]; then
            log err "[BACKUP] Template not found: $template"
            return 1
        fi

        if [[ -e "$script_target" && "$force_update" != true ]]; then
            log warn "[BACKUP] Target script exists: $script_target (use --force to overwrite)"
            return 0
        fi

        log info "[BACKUP] Writing remote backup template to: $script_target"
        cp "$template" "$script_target" || {
            log err "[BACKUP] Failed to write $script_target"
            return 1
        }

        chmod +x "$script_target" 2>/dev/null || true
        if [[ -n "${INM_ENFORCED_USER:-}" ]]; then
            log info "[BACKUP] Prefill suggestion: set REMOTE_USER=\"$INM_ENFORCED_USER\" inside $script_target"
        fi
        log ok "[BACKUP] Remote backup script created: $script_target"
        return 0
    fi

    if [[ "$fullbackup" == "true" ]]; then
        db=true
        storage=true
        uploads=true
    else
        [[ "$db" == "true" || "$storage" == "true" || "$uploads" == "true" ]] && fullbackup=false
    fi

    local ts
    ts="$(date +%Y-%m-%d_%H-%M)"
    local base_name="${INM_PROGRAM_NAME:-invoiceninja}_${name}_${ts}"

    local db_file="$INM_BACKUP_DIRECTORY/${base_name}_db.sql"
    local storage_file="$INM_BACKUP_DIRECTORY/${base_name}_storage.tar.gz"
    local uploads_file="$INM_BACKUP_DIRECTORY/${base_name}_uploads.tar.gz"
    local app_file="$INM_BACKUP_DIRECTORY/${base_name}_app.tar.gz"
    local extra_file="$INM_BACKUP_DIRECTORY/${base_name}_extra.tar.gz"
    local bundle_file="$INM_BACKUP_DIRECTORY/${base_name}_full"
    local simulate="${DRY_RUN:-false}"
    local planned_parts=()
    local extra_paths=()

    [[ "$compress" == "zip" ]] && bundle_file+=".zip"
    [[ "$compress" == "tar.gz" ]] && bundle_file+=".tar.gz"
    [[ "$compress" == "false" ]] && bundle_file+=".bak"
    [[ "$compress" == "zip" ]] && extra_file="${extra_file%.tar.gz}.zip"
    [[ "$compress" == "false" ]] && extra_file="${extra_file%.tar.gz}.bak"

    if [[ -n "$extra_paths_raw" ]]; then
        IFS=',' read -ra extra_paths <<<"$extra_paths_raw"
    fi

    log info "[BACKUP] Preparing backup in: $INM_BACKUP_DIRECTORY"
    log debug "[BACKUP] Parts → db:${db} storage:${storage} uploads:${uploads} app:${include_app} extra:${#extra_paths[@]} bundle:${bundle} compress:${compress} (dry-run=${simulate})"

    # Plan parts regardless of dry-run
    [[ "$db" == "true" ]] && planned_parts+=("$db_file")
    [[ "$storage" == "true" ]] && planned_parts+=("$storage_file")
    [[ "$uploads" == "true" ]] && planned_parts+=("$uploads_file")
    [[ "$include_app" == "true" ]] && planned_parts+=("$app_file")
    [[ ${#extra_paths[@]} -gt 0 ]] && planned_parts+=("$extra_file")

    if [[ "$simulate" != true ]]; then
        mkdir -p "$INM_BACKUP_DIRECTORY" || {
            log err "[BACKUP] Cannot create backup directory: $INM_BACKUP_DIRECTORY"
            return 1
        }
    else
        log info "[DRY-RUN] Would create backup directory: $INM_BACKUP_DIRECTORY"
    fi

    local install_root="${INM_INSTALLATION_PATH:-${INM_BASE_DIRECTORY%/}/${INM_INSTALLATION_DIRECTORY#/}}"

    if [[ "$db" == "true" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would dump database to $db_file"
        else
            log info "[BACKUP] Starting database dump..."
            dump_database "$db_file" || return 1
        fi
    fi

    if [[ "$storage" == "true" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would archive storage/ -> $storage_file"
        else
            log info "[BACKUP] Archiving storage/"
            if ! tar -czf "$storage_file" -C "$install_root" storage; then
                log err "[BACKUP] Archiving storage failed (path: $install_root/storage)."
                return 1
            fi
            log ok "[BACKUP] Storage archived: $storage_file"
        fi
    fi

    if [[ "$uploads" == "true" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would archive uploads/logo -> $uploads_file"
        else
            log info "[BACKUP] Archiving uploads/"
            if ! tar -czf "$uploads_file" -C "$install_root/public" uploads logo 2>/dev/null; then
                log warn "[BACKUP] Archiving uploads/logo failed (path missing? $install_root/public)."
            else
                log ok "[BACKUP] Uploads archived: $uploads_file"
            fi
        fi
    fi

    if [[ "$include_app" == "true" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would archive app (excluding storage/uploads) -> $app_file"
        else
            log info "[BACKUP] Archiving app (excluding storage/uploads)"
            if ! tar -czf "$app_file" -C "$install_root" --exclude storage --exclude 'public/uploads' .; then
                log warn "[BACKUP] Archiving app failed (path: $install_root)."
            else
                log ok "[BACKUP] App archived: $app_file"
            fi
        fi
    fi

    # Extra paths archive
    if [[ ${#extra_paths[@]} -gt 0 ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would archive extra paths (${extra_paths[*]}) -> $extra_file"
        else
            log info "[BACKUP] Archiving extra paths: ${extra_paths[*]}"
            if [[ "$compress" == "zip" ]]; then
                (cd "$install_root" && zip -r "$extra_file" "${extra_paths[@]}") >/dev/null || \
                    log warn "[BACKUP] Archiving extra paths failed (zip)."
            else
                if ! tar -czf "$extra_file" -C "$install_root" "${extra_paths[@]}" 2>/dev/null; then
                    log warn "[BACKUP] Archiving extra paths failed (tar)."
                else
                    log ok "[BACKUP] Extra paths archived: $extra_file"
                fi
            fi
        fi
    fi

    local bundle_parts=()
    if [[ "$simulate" == true ]]; then
        bundle_parts=("${planned_parts[@]}")
    else
        [[ -f "$db_file" ]] && bundle_parts+=("$db_file")
        [[ -f "$storage_file" ]] && bundle_parts+=("$storage_file")
        [[ -f "$uploads_file" ]] && bundle_parts+=("$uploads_file")
        [[ -f "$app_file" ]] && bundle_parts+=("$app_file")
        [[ -f "$extra_file" ]] && bundle_parts+=("$extra_file")
    fi

    if [[ "$bundle" == "true" ]]; then
        if [ ${#bundle_parts[@]} -eq 0 ]; then
            log warn "[BACKUP] Bundle requested, but no parts were selected. Skipping bundle."
            return 0
        fi
        log info "[BACKUP] Creating bundle: $bundle_file"

        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would bundle parts (${bundle_parts[*]}) -> $bundle_file"
        else
            if [[ "$compress" == "zip" ]]; then
                zip -j "$bundle_file" "${bundle_parts[@]}" >/dev/null
            elif [[ "$compress" == "tar.gz" ]]; then
                tar -czf "$bundle_file" -C "$INM_BACKUP_DIRECTORY" "$(basename -a "${bundle_parts[@]}")"
            else
                cat "${bundle_parts[@]}" > "$bundle_file"
            fi
            log ok "[BACKUP] Bundle created: $bundle_file"
            rm -f "$db_file" "$storage_file" "$uploads_file" "$app_file" "$extra_file"
            bundle_parts=("$bundle_file")
        fi
    fi

    # Checksums for integrity
    local checksum_target=""
    if [[ "$simulate" == true ]]; then
        log info "[DRY-RUN] Would create checksums for: ${bundle_parts[*]:-bundle $bundle_file}"
    else
        if [[ -f "$bundle_file" ]]; then
            checksum_target="$bundle_file.sha256"
            (cd "$INM_BACKUP_DIRECTORY" && sha256sum "$(basename "$bundle_file")" > "$(basename "$checksum_target")") && \
                log ok "[BACKUP] Checksum written: $checksum_target"
        else
            for f in "${bundle_parts[@]}"; do
                if [[ -f "$f" ]]; then
                    local cfile="${f}.sha256"
                    (cd "$(dirname "$f")" && sha256sum "$(basename "$f")" > "$(basename "$cfile")") && \
                        log ok "[BACKUP] Checksum written: $cfile"
                fi
            done
        fi
    fi

    # Manifest
    local manifest="$INM_BACKUP_DIRECTORY/${base_name}_manifest.txt"
    if [[ "$simulate" == true ]]; then
        log info "[DRY-RUN] Would write manifest: $manifest"
    else
        {
            echo "name=$base_name"
            echo "created=$(date '+%Y-%m-%d %H:%M:%S')"
            echo "compress=$compress"
            echo "bundle=$bundle"
            echo "parts=${bundle_parts[*]}"
            echo "include_app=$include_app"
            echo "extra_paths=${extra_paths[*]}"
        } > "$manifest"
        log ok "[BACKUP] Manifest written: $manifest"
    fi

    log info "[BACKUP] Completed. Base name: $base_name"
    if [[ "$bundle" == "true" ]]; then
        [[ -f "$bundle_file" || "$simulate" == true ]] && log info "[BACKUP] Bundle at: $bundle_file"
    else
        [[ -f "$db_file" || "$simulate" == true ]] && log info "[BACKUP] DB dump: $db_file"
        [[ -f "$storage_file" || "$simulate" == true ]] && log info "[BACKUP] Storage: $storage_file"
        [[ -f "$uploads_file" || "$simulate" == true ]] && log info "[BACKUP] Uploads: $uploads_file"
        [[ -f "$app_file" || "$simulate" == true ]] && [[ "$include_app" == "true" ]] && log info "[BACKUP] App archive: $app_file"
    fi
}
