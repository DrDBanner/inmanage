#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_RESTORE_LOADED:-} ]] && return
__SERVICE_RESTORE_LOADED=1

# ---------------------------------------------------------------------
# run_restore()
# Restores from a backup bundle/directory or individual part (db/app/files).
# Detects new flat bundle layout (real folders/files, no nested archives).
# ---------------------------------------------------------------------
run_restore() {
    declare -A ARGS
    parse_named_args ARGS "$@"

    local bundle="${ARGS[file]:-${ARGS[bundle]:-}}"
    local force="${ARGS[force]:-${force_update:-false}}"
    local include_app="${ARGS[include_app]:-${ARGS[include-app]:-true}}"
    local target_arg="${ARGS[target]:-${ARGS[bundle_target]:-}}"
    local target_default="${INM_INSTALLATION_PATH:-${INM_BASE_DIRECTORY%/}/${INM_INSTALLATION_DIRECTORY#/}}"
    local target="${target_arg:-$target_default}"
    local prebackup="${ARGS[pre_backup]:-${ARGS[pre-backup]:-true}}"
    local purge="${ARGS[purge_db]:-${ARGS[purge]:-true}}"
    local autofill="${ARGS[autofill_missing]:-${ARGS[autofill-missing]:-${ARGS[autoheal]:-1}}}"
    local autofill_app="${ARGS[autofill_missing_app]:-${ARGS[autofill-missing-app]:-${ARGS[autoheal_app]:-${ARGS[autoheal-app]:-$autofill}}}}"
    local autofill_db="${ARGS[autofill_missing_db]:-${ARGS[autofill-missing-db]:-${ARGS[autoheal_db]:-${ARGS[autoheal-db]:-$autofill}}}}"
    local simulate="${DRY_RUN:-false}"

    if [[ "$simulate" != true ]]; then
        mkdir -p "$INM_BACKUP_DIRECTORY" 2>/dev/null || true
    else
        log info "[DRY-RUN] Would ensure backup directory exists: $INM_BACKUP_DIRECTORY"
    fi

    if [[ -z "$bundle" ]]; then
        local candidates=()
        if [[ -d "$INM_BACKUP_DIRECTORY" ]]; then
            log info "[RESTORE] Looking for backups in: $INM_BACKUP_DIRECTORY"
            while IFS= read -r entry; do
                local path="$INM_BACKUP_DIRECTORY/$entry"
                [[ "$entry" == *.sha256 ]] && continue
                if [[ -f "$path" || -d "$path" ]]; then
                    candidates+=("$path")
                fi
            done < <(ls -1t "$INM_BACKUP_DIRECTORY" 2>/dev/null)
        fi

        if [[ ${#candidates[@]} -eq 0 ]]; then
            log err "[RESTORE] No backup found. Provide --file=<bundle>."
            return 1
        fi

        if [[ "${NAMED_ARGS[latest]:-${NAMED_ARGS[file_latest]:-${NAMED_ARGS[file-latest]:-false}}}" == "true" ]]; then
            bundle="${candidates[0]}"
            log info "[RESTORE] --latest requested; auto-selecting newest: $bundle"
        else
            log info "[RESTORE] Found ${#candidates[@]} backup item(s); prompting for selection."
            if [[ ! -t 0 && "${NAMED_ARGS[auto_select]:-${NAMED_ARGS[auto-select]:-}}" != "true" ]]; then
                log err "[RESTORE] Cannot prompt without TTY. Re-run with --file=<path> or --auto-select=true to pick the newest automatically."
                return 1
            fi
            bundle="$(select_from_candidates "Select a backup to restore" "${candidates[@]}")" || return 1
        fi
    fi

    if [[ ! -e "$bundle" ]]; then
        log err "[RESTORE] Path not found: $bundle"
        return 1
    fi

    bundle="$(cd "$(dirname "$bundle")" && pwd)/$(basename "$bundle")"
    log info "[RESTORE] Using bundle: $bundle"
    log info "[RESTORE] Target app dir: $target"
    log debug "[RESTORE] include_app=${include_app} force=${force} prebackup=${prebackup} purge=${purge} autofill_app=${autofill_app} autofill_db=${autofill_db}"
    [[ "$simulate" == true ]] && log info "[DRY-RUN] Restore simulation only (no changes)."

    if [[ "$simulate" == true ]]; then
        log info "[DRY-RUN] Would restore from: $bundle -> $target (include_app=$include_app, purge_db=$purge, prebackup=$prebackup)"
        return 0
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    cleanup_tmp_restore() { safe_rm_rf "$tmpdir" "$(dirname "$tmpdir")" || true; }
    trap cleanup_tmp_restore EXIT

    local stage_root="$tmpdir"
    if [[ -d "$bundle" ]]; then
        log info "[RESTORE] Using bundle directory: $bundle"
        cp -a "$bundle"/. "$stage_root"/ || { log err "[RESTORE] Failed to stage bundle directory."; return 1; }
    else
        case "$bundle" in
            *.tar.gz|*.tgz)
                log info "[RESTORE] Extracting tar bundle -> $stage_root"
                if declare -F tar_safe_extract >/dev/null 2>&1; then
                    tar_safe_extract "$bundle" "$stage_root" || { log err "[RESTORE] Failed to extract bundle."; return 1; }
                else
                    tar -xzf "$bundle" -C "$stage_root" || { log err "[RESTORE] Failed to extract bundle."; return 1; }
                fi
                ;;
            *.zip)
                log info "[RESTORE] Extracting zip bundle -> $stage_root"
                if declare -F zip_safe_extract >/dev/null 2>&1; then
                    zip_safe_extract "$bundle" "$stage_root" || { log err "[RESTORE] Failed to extract bundle."; return 1; }
                else
                    unzip -q "$bundle" -d "$stage_root" || { log err "[RESTORE] Failed to extract bundle."; return 1; }
                fi
                ;;
            *)
                log info "[RESTORE] Staging file -> $stage_root"
                cp "$bundle" "$stage_root/" || { log err "[RESTORE] Failed to stage file: $bundle"; return 1; }
                ;;
        esac
    fi

    local db_part env_part storage_dir uploads_dir extra_dir app_dir
    local app_missing=false
    db_part=$(find "$stage_root" -maxdepth 4 -type f \( -name "db.sql" -o -name "*_db.sql" \) | head -n1)
    env_part=$(find "$stage_root" -maxdepth 4 -type f \( -name ".env" -o -name "*_env" \) | head -n1)
    storage_dir=$(find "$stage_root" -maxdepth 3 -type d -name "storage" | head -n1)
    uploads_dir=$(find "$stage_root" -maxdepth 4 -type d \( -path "*/public/uploads" -o -name "uploads" \) | head -n1)
    extra_dir=$(find "$stage_root" -maxdepth 2 -type d -name "extra" | head -n1)

    local app_hint="${INM_INSTALLATION_DIRECTORY#/}"
    local app_hint_base="$(basename "${INM_INSTALLATION_PATH:-$target_default}")"
    if [[ -n "$app_hint" && -d "$stage_root/$app_hint" ]]; then
        app_dir="$stage_root/$app_hint"
    elif [[ -n "$app_hint_base" && -d "$stage_root/$app_hint_base" ]]; then
        app_dir="$stage_root/$app_hint_base"
    else
        while IFS= read -r d; do
            local base="$(basename "$d")"
            [[ "$base" == "storage" || "$base" == "public" || "$base" == "extra" ]] && continue
            app_dir="$d"
            break
        done < <(find "$stage_root" -mindepth 1 -maxdepth 1 -type d)
    fi

    if [[ -z "$db_part" && -z "$env_part" && -z "$storage_dir" && -z "$uploads_dir" && -z "$app_dir" && -z "$extra_dir" ]]; then
        log err "[RESTORE] No recognizable backup content found."
        return 1
    fi

    # Warn if no .env is present; without APP_KEY, encrypted secrets (gateway/mail/API/2FA) will be unusable.
    if [[ -z "$env_part" ]]; then
        if [[ "$simulate" == true ]]; then
            log warn "[DRY-RUN] No .env found in backup. Without APP_KEY, encrypted secrets (payment/mail/API/2FA) will be lost; users will need to re-enter them."
        else
            log warn "[RESTORE] No .env found in backup. Without APP_KEY, encrypted secrets (payment/mail/API/2FA) will be lost; users must re-enter them."
            if [[ "$force" != true ]]; then
                log info "[RESTORE] Continue without .env? (yes/no): "
                local cont_env=""
                read -r cont_env
                if [[ ! "$cont_env" =~ ^([Yy]([Ee][Ss])?)$ ]]; then
                    log err "[RESTORE] Aborted due to missing .env."
                    return 1
                fi
            fi
        fi
    fi

    if [[ "$include_app" == true && -d "$target" ]]; then
        local pre_restore_backup="${INM_BACKUP_DIRECTORY%/}/restore_pre_$(date +%Y%m%d-%H%M%S)"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would move existing app to $pre_restore_backup before restore."
        else
            mkdir -p "$pre_restore_backup" || { log err "[RESTORE] Cannot create backup dir: $pre_restore_backup"; return 1; }
            log info "[RESTORE] Moving existing app to backup: $pre_restore_backup"
            safe_move_or_copy_and_clean "$target" "$pre_restore_backup" move || { log err "[RESTORE] Failed to backup existing app to $pre_restore_backup"; return 1; }
        fi
    fi
    [[ "$simulate" != true ]] && mkdir -p "$target"

    if [[ "$include_app" == true && -n "$app_dir" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore application files -> $target"
        else
            log info "[RESTORE] Restoring application files via rsync -> $target"
            rsync -a "$app_dir"/ "$target"/ || { log err "[RESTORE] Failed to restore application files."; return 1; }
        fi
    elif [[ "$include_app" == true ]]; then
        if [[ "$autofill_app" != "0" ]]; then
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would download and install a fresh app because backup lacks app files."
            else
                log warn "[RESTORE] No application directory found in backup. Attempting fresh install (autofill app)."
                local saved_named=("${NAMED_ARGS[@]}")
                NAMED_ARGS[clean]=true
                call_with_named_args run_installation ""
                NAMED_ARGS=("${saved_named[@]}")
            fi
        else
            log warn "[RESTORE] No application directory in backup and autofill-app disabled; app files will be missing."
            app_missing=true
        fi
    fi

    if [[ -n "$storage_dir" ]]; then
        local storage_dest="$target/storage"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore storage -> $storage_dest"
        else
            log info "[RESTORE] Restoring storage via rsync -> $storage_dest"
            mkdir -p "$storage_dest"
            rsync -a "$storage_dir"/ "$storage_dest"/ || log warn "[RESTORE] Restoring storage failed."
        fi
    fi

    if [[ -n "$uploads_dir" ]]; then
        local uploads_dest="$target/public/uploads"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore uploads -> $uploads_dest"
        else
            log info "[RESTORE] Restoring uploads via rsync -> $uploads_dest"
            mkdir -p "$uploads_dest"
            rsync -a "$uploads_dir"/ "$uploads_dest"/ || log warn "[RESTORE] Restoring uploads failed."
        fi
    fi

    if [[ -n "$extra_dir" ]]; then
        local extra_dest="$target/extra"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore extra paths -> $extra_dest"
        else
            log info "[RESTORE] Restoring extra paths via rsync -> $extra_dest"
            mkdir -p "$extra_dest"
            rsync -a "$extra_dir"/ "$extra_dest"/ || log warn "[RESTORE] Restoring extra paths failed."
        fi
    fi

    local user_ini_src=""
    user_ini_src=$(find "$stage_root" -maxdepth 5 -type f -name ".user.ini" 2>/dev/null | head -n1)
    if [[ -n "$user_ini_src" ]]; then
        local user_ini_dest="$target/public/.user.ini"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore .user.ini -> $user_ini_dest"
        else
            if [[ -f "$user_ini_dest" && "$force" != true ]]; then
                log warn "[RESTORE] .user.ini exists at $user_ini_dest (use --force to overwrite)."
            else
                mkdir -p "$(dirname "$user_ini_dest")"
                if cp "$user_ini_src" "$user_ini_dest"; then
                    log info "[RESTORE] Restored .user.ini -> $user_ini_dest"
                else
                    log warn "[RESTORE] Failed to restore .user.ini."
                fi
            fi
        fi
    fi

    local restored_env=""
    if [[ -n "$env_part" ]]; then
        local env_dest="${target%/}/.env"
        restored_env="$env_dest"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would restore .env -> $env_dest"
        else
            if [[ -f "$env_dest" && "$force" != true ]]; then
                log warn "[RESTORE] .env exists at $env_dest (use --force to overwrite)."
            else
                log info "[RESTORE] Restoring .env -> $env_dest"
                mkdir -p "$(dirname "$env_dest")"
                cp "$env_part" "$env_dest" || log warn "[RESTORE] Failed to restore .env."
            fi
        fi
    fi

    if [[ -n "$db_part" ]]; then
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would import database from $db_part"
        else
            if [[ -n "$restored_env" && -f "$restored_env" ]]; then
                if ! grep -q '^APP_KEY=' "$restored_env"; then
                    log warn "[RESTORE] APP_KEY missing in restored .env ($restored_env). Encrypted secrets (payment/mail/API/2FA) will be unusable until replaced."
                    if [[ "$force" != true ]]; then
                        log info "[RESTORE] Continue without APP_KEY? (yes/no): "
                        local cont=""
                        read -r cont
                        if [[ ! "$cont" =~ ^([Yy]([Ee][Ss])?)$ ]]; then
                            log err "[RESTORE] Aborted due to missing APP_KEY."
                            return 1
                        fi
                    fi
                fi
            fi
            log info "[RESTORE] Importing database from $db_part"
            import_database --file="$db_part" --force="$force" --pre-backup="$prebackup" --purge_before_import="$purge"
        fi
    else
        if [[ "$simulate" == true ]]; then
            log warn "[DRY-RUN] No DB dump in backup. Would prompt for alternative or fresh seed."
        else
            log warn "[RESTORE] No DB dump found. Provide a path to import, type 'fresh' to migrate/seed, or leave empty to abort."
            printf "Enter SQL file path or 'fresh' (empty to abort): "
            local choice=""
            read -r choice
            if [[ -z "$choice" ]]; then
                log err "[RESTORE] Aborting. Rerun with --file=<backup> or use autofill-db=1 with --force to bypass prompts."
                return 1
            elif [[ "$choice" == "fresh" ]]; then
                if [[ "$autofill_db" == "0" ]]; then
                    log err "[RESTORE] Autofill-db disabled and no SQL provided; aborting."
                    return 1
                fi
                log info "[RESTORE] Running migrate:fresh --seed."
                run_artisan migrate:fresh --seed --force || { log err "[RESTORE] Fresh migrate/seed failed."; return 1; }
            else
                if [[ ! -f "$choice" ]]; then
                    log err "[RESTORE] SQL file not found: $choice"
                    return 1
                fi
                # Basic validation: must contain CREATE TABLE or INSERT to look like SQL
                if ! grep -qiE "CREATE TABLE|INSERT INTO" "$choice" 2>/dev/null; then
                    log warn "[RESTORE] SQL file does not appear to contain table/data statements. Proceeding may fail."
                fi
                log info "[RESTORE] Importing database from $choice"
                import_database --file="$choice" --force="$force" --pre-backup="$prebackup" --purge_before_import="$purge"
            fi
        fi
    fi

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

    if [[ "$include_app" == true ]]; then
        if ! app_sanity_check "$target"; then
            log warn "[RESTORE] App sanity check failed. Consider running 'inmanage core update --force'."
            app_missing=true
        fi
    fi

    if command -v du >/dev/null 2>&1; then
        local target_size
        target_size=$(du -sh "$target" 2>/dev/null | awk '{print $1}')
        [[ -n "$target_size" ]] && log info "[RESTORE] Target footprint: $target_size at $target"
    fi

    # Final verdict on install readiness
    if [[ "$include_app" == true ]]; then
        if [[ "$app_missing" == true ]]; then
            log err "[RESTORE] Installation not ready: missing critical app files."
        elif [[ ! -f "${target%/}/.env" ]]; then
            log err "[RESTORE] Installation not ready: .env missing at ${target%/}/.env."
        else
            log ok "[RESTORE] Installation appears complete. Consider running 'inmanage core update' to ensure the latest version."
        fi
        if [[ "$simulate" != true ]]; then
            enforce_ownership "$target"
            enforce_permissions 750 "$target"
        else
            log info "[DRY-RUN] Would enforce ownership and permissions (750) on $target"
        fi
    fi

    local suffix=""
    [[ "$simulate" == true ]] && suffix=" (dry-run)"
    log ok "[RESTORE] Restore flow completed${suffix}."
}
