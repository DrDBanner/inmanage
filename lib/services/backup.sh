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
        include_app=true
        bundle=true
        single_bundle=true
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
    local single_bundle=false

    # default: if nothing specified, take full backup
    if [[ -z "${ARGS[db]}" && -z "${ARGS[storage]}" && -z "${ARGS[uploads]}" && -z "${ARGS[include_app]}" && -z "${ARGS[include-app]}" && -z "${ARGS[extra_paths]}" && -z "${ARGS[extra]}" ]]; then
        db=true
        storage=true
        uploads=true
        include_app=true
        bundle=true
        single_bundle=true
    fi

    [[ "$compress" == "zip" ]] && bundle_file+=".zip"
    [[ "$compress" == "tar.gz" ]] && bundle_file+=".tar.gz"
    # compress=false -> keep bundle_file as directory target (no suffix)
    [[ "$compress" == "zip" ]] && extra_file="${extra_file%.tar.gz}.zip"
    [[ "$compress" == "false" ]] && extra_file="${extra_file%.tar.gz}"

    if [[ -n "$extra_paths_raw" ]]; then
        IFS=',' read -ra extra_paths <<<"$extra_paths_raw"
    fi

    log info "[BACKUP] Preparing backup in: $INM_BACKUP_DIRECTORY"
    log debug "[BACKUP] Parts → db:${db} storage:${storage} uploads:${uploads} app:${include_app} extra:${#extra_paths[@]} bundle:${bundle} compress:${compress} (dry-run=${simulate})"

    # Plan parts regardless of dry-run (only for multi-part mode)
    if [[ "$single_bundle" != true ]]; then
        [[ "$db" == "true" ]] && planned_parts+=("$db_file")
        [[ "$storage" == "true" ]] && planned_parts+=("$storage_file")
        [[ "$uploads" == "true" ]] && planned_parts+=("$uploads_file")
        [[ "$include_app" == "true" ]] && planned_parts+=("$app_file")
        [[ ${#extra_paths[@]} -gt 0 ]] && planned_parts+=("$extra_file")
    fi

    if [[ "$simulate" != true ]]; then
        mkdir -p "$INM_BACKUP_DIRECTORY" || {
            log err "[BACKUP] Cannot create backup directory: $INM_BACKUP_DIRECTORY"
            return 1
        }
    else
        log info "[DRY-RUN] Would create backup directory: $INM_BACKUP_DIRECTORY"
    fi

    local install_root="${INM_INSTALLATION_PATH:-${INM_BASE_DIRECTORY%/}/${INM_INSTALLATION_DIRECTORY#/}}"

    if [[ "$single_bundle" == true ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would create single full bundle -> $bundle_file"
        else
            local stage
            stage="$(mktemp -d)"
            # dump DB into staging
            log info "[BACKUP] Starting database dump..."
            dump_database "$stage/db.sql" || { rm -rf "$stage"; return 1; }
            # sync entire app (exclude backup dir and .cache to avoid recursion)
            local staged_app="$stage/$(basename "$INM_INSTALLATION_DIRECTORY")"
            rsync -a --delete --exclude "$(basename "$INM_BACKUP_DIRECTORY")" --exclude ".cache" "$install_root"/ "$staged_app/" || {
                log err "[BACKUP] Failed to stage app files for bundle."
                rm -rf "$stage"; return 1;
            }
            # copy app .env into staged app if present
            local app_env="${INM_ENV_FILE:-${install_root}/.env}"
            if [[ -f "$app_env" ]]; then
                cp "$app_env" "$staged_app/.env" 2>/dev/null || log warn "[BACKUP] Could not copy .env into bundle"
            fi
            # create single bundle
            case "$compress" in
                zip)
                    (cd "$stage" && zip -r "$bundle_file" .) >/dev/null && log ok "[BACKUP] Bundle created: $bundle_file" || log err "[BACKUP] Failed to create bundle: $bundle_file"
                    ;;
                false)
                    rm -rf "$bundle_file"
                    mkdir -p "$bundle_file"
                    if rsync -a "$stage"/ "$bundle_file"/; then
                        log ok "[BACKUP] Bundle directory created: $bundle_file"
                    else
                        log err "[BACKUP] Failed to create bundle directory: $bundle_file"
                    fi
                    ;;
                *)
                    tar -czf "$bundle_file" -C "$stage" . && log ok "[BACKUP] Bundle created: $bundle_file" || log err "[BACKUP] Failed to create bundle: $bundle_file"
                    ;;
            esac
            rm -rf "$stage"
        fi
        # In single bundle mode we skip the rest
        [[ "$simulate" == true ]] && log info "[DRY-RUN] Full bundle planned: $bundle_file"
        if [[ "$simulate" != true && "$bundle" == "true" ]]; then
            [[ "$compress" == "false" ]] && bundle_parts=() || bundle_parts=("$bundle_file")
        fi
        if [[ "$simulate" != true && "$compress" != "false" && -f "$bundle_file" ]]; then
            planned_parts=("$bundle_file")
        fi
        # Checksum
        if [[ "$simulate" != true && "$compress" != "false" && -f "$bundle_file" ]]; then
            local checksum_target="$bundle_file.sha256"
            (cd "$INM_BACKUP_DIRECTORY" && sha256sum "$(basename "$bundle_file")" > "$(basename "$checksum_target")") && \
                log ok "[BACKUP] Checksum written: $checksum_target"
        fi
        log info "[BACKUP] Completed. Base name: $base_name"
        return 0
    fi

    if [[ "$db" == "true" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would dump database to $db_file"
        else
            log info "[BACKUP] Starting database dump..."
            dump_database "$db_file" || return 1
        fi
    fi

    # App .env (if present)
    local env_file="${INM_ENV_FILE:-${install_root}/.env}"
    if [[ -f "$env_file" ]]; then
        local env_target="$INM_BACKUP_DIRECTORY/${base_name}_env"
        [[ "$compress" == "tar.gz" ]] && env_target+=".tar.gz"
        [[ "$compress" == "zip" ]] && env_target="${env_target%.tar.gz}.zip"
        [[ "$compress" == "false" ]] && env_target="${env_target%.tar.gz}.bak"

        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would copy .env -> $env_target"
            planned_parts+=("$env_target")
        else
            case "$compress" in
                zip)
                    (cd "$(dirname "$env_file")" && zip -j "$env_target" "$(basename "$env_file")") >/dev/null && log ok "[BACKUP] .env archived: $env_target" || log warn "[BACKUP] Could not archive .env"
                    ;;
                tar.gz)
                    mkdir -p "$(dirname "$env_target")" 2>/dev/null || true
                    (cd "$(dirname "$env_file")" && tar -czf "$env_target" "$(basename "$env_file")") && log ok "[BACKUP] .env archived: $env_target" || log warn "[BACKUP] Could not archive .env"
                    ;;
                *)
                    cp "$env_file" "$env_target" && log ok "[BACKUP] .env copied: $env_target" || log warn "[BACKUP] Could not copy .env"
                    ;;
            esac
            [[ -f "$env_target" ]] && bundle_parts+=("$env_target")
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
                # Build basename array without mapfile dependency
                local _bundle_baseparts=()
                for _bp in "${bundle_parts[@]}"; do
                    _bundle_baseparts+=("$(basename "$_bp")")
                done
                tar -czf "$bundle_file" -C "$INM_BACKUP_DIRECTORY" "${_bundle_baseparts[@]}"
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
