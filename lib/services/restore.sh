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
    # shellcheck disable=SC2034
    declare -A ARGS
    parse_named_args ARGS "$@"

    local bundle
    bundle="$(args_get ARGS "" file bundle)"
    local force
    force="$(args_get ARGS "${force_update:-false}" force)"
    if args_is_true "$force"; then
        force=true
    else
        force=false
    fi
    local include_app
    include_app="$(args_get ARGS "true" include_app)"
    if args_is_true "$include_app"; then
        include_app=true
    else
        include_app=false
    fi
    local target_arg
    target_arg="$(args_get ARGS "" target bundle_target)"
    local target_default="${INM_INSTALLATION_PATH:-${INM_BASE_DIRECTORY%/}/${INM_INSTALLATION_DIRECTORY#/}}"
    local target="${target_arg:-$target_default}"
    local prebackup
    prebackup="$(args_get ARGS "true" pre_backup)"
    if args_is_true "$prebackup"; then
        prebackup=true
    else
        prebackup=false
    fi
    local purge
    purge="$(args_get ARGS "true" purge_db purge)"
    if args_is_true "$purge"; then
        purge=true
    else
        purge=false
    fi
    local autofill
    autofill="$(args_get ARGS "1" autofill_missing autoheal)"
    local autofill_app
    autofill_app="$(args_get ARGS "$autofill" autofill_missing_app autoheal_app)"
    local autofill_db
    autofill_db="$(args_get ARGS "$autofill" autofill_missing_db autoheal_db)"
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
                [[ "$entry" == restore_pre_* ]] && continue
                if [[ -f "$path" || -d "$path" ]]; then
                    candidates+=("$path")
                fi
            done < <(ls -1t "$INM_BACKUP_DIRECTORY" 2>/dev/null)
        fi

        if [[ ${#candidates[@]} -eq 0 ]]; then
            log err "[RESTORE] No backup found. Provide --file=<bundle>."
            return 1
        fi

        local latest
        latest="$(args_get ARGS "false" latest file_latest)"
        if args_is_true "$latest"; then
            bundle="${candidates[0]}"
            log info "[RESTORE] --latest requested; auto-selecting newest: $bundle"
        else
            log info "[RESTORE] Found ${#candidates[@]} backup item(s); prompting for selection."
            local auto_select
            auto_select="$(args_get ARGS "" auto_select)"
            if [[ ! -t 0 ]] && ! args_is_true "$auto_select"; then
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

    if ! args_is_true "$force"; then
        local bundle_has_db=false
        if [[ -d "$bundle" ]]; then
            if find "$bundle" -maxdepth 4 -type f \( -name "db.sql" -o -name "*_db.sql" \) -print -quit | grep -q .; then
                bundle_has_db=true
            fi
        else
            case "$bundle" in
                *.sql)
                    bundle_has_db=true
                    ;;
                *.tar.gz|*.tgz)
                    if tar -tzf "$bundle" 2>/dev/null | grep -qE '(^|/)(db\.sql|[^/]*_db\.sql)$'; then
                        bundle_has_db=true
                    fi
                    ;;
                *.zip)
                    if unzip -l "$bundle" 2>/dev/null | grep -qE '(^|/)(db\.sql|[^/]*_db\.sql)$'; then
                        bundle_has_db=true
                    fi
                    ;;
            esac
        fi
        if [[ "$bundle_has_db" == true ]]; then
            log err "[RESTORE] Database restore is destructive. Re-run with --force to proceed."
            return 1
        fi
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2329
    cleanup_tmp_restore() {
        local dir="$1"
        [[ -n "$dir" ]] || return 0
        safe_rm_rf "$dir" "$(dirname "$dir")" || true
    }
    trap 'cleanup_tmp_restore "$tmpdir"; trap - RETURN' RETURN

    local stage_root="$tmpdir"
    if [[ -d "$bundle" ]]; then
        log info "[RESTORE] Using bundle directory: $bundle"
        if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Staging bundle directory..." cp -a "$bundle"/. "$stage_root"/; then
            log err "[RESTORE] Failed to stage bundle directory."
            return 1
        fi
    else
        case "$bundle" in
            *.tar.gz|*.tgz)
                log info "[RESTORE] Extracting tar bundle -> $stage_root"
                if declare -F tar_safe_extract >/dev/null 2>&1; then
                    if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Extracting backup..." tar_safe_extract "$bundle" "$stage_root"; then
                        log err "[RESTORE] Failed to extract bundle."
                        return 1
                    fi
                else
                    if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Extracting backup..." tar -xzf "$bundle" -C "$stage_root"; then
                        log err "[RESTORE] Failed to extract bundle."
                        return 1
                    fi
                fi
                ;;
            *.zip)
                log info "[RESTORE] Extracting zip bundle -> $stage_root"
                if declare -F zip_safe_extract >/dev/null 2>&1; then
                    if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Extracting backup..." zip_safe_extract "$bundle" "$stage_root"; then
                        log err "[RESTORE] Failed to extract bundle."
                        return 1
                    fi
                else
                    if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Extracting backup..." unzip -q "$bundle" -d "$stage_root"; then
                        log err "[RESTORE] Failed to extract bundle."
                        return 1
                    fi
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
    local app_hint_base
    app_hint_base="$(basename "${INM_INSTALLATION_PATH:-$target_default}")"
    if [[ -n "$app_hint" && -d "$stage_root/$app_hint" ]]; then
        app_dir="$stage_root/$app_hint"
    elif [[ -n "$app_hint_base" && -d "$stage_root/$app_hint_base" ]]; then
        app_dir="$stage_root/$app_hint_base"
    else
        while IFS= read -r d; do
            local base
            base="$(basename "$d")"
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
                if ! prompt_confirm "RESTORE_NO_ENV" "no" "[RESTORE] Continue without .env? (yes/no):" false 60; then
                    log err "[RESTORE] Aborted due to missing .env."
                    return 1
                fi
            fi
        fi
    fi

    if [[ "$include_app" == true && -d "$target" ]]; then
        local pre_restore_backup
        pre_restore_backup="${INM_BACKUP_DIRECTORY%/}/restore_pre_$(date +%Y%m%d-%H%M%S)"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would move existing app to $pre_restore_backup before restore."
        else
            mkdir -p "$pre_restore_backup" || { log err "[RESTORE] Cannot create backup dir: $pre_restore_backup"; return 1; }
            log info "[RESTORE] Moving existing app to backup: $pre_restore_backup"
            safe_move_or_copy_and_clean "$target" "$pre_restore_backup" move || { log err "[RESTORE] Failed to backup existing app to $pre_restore_backup"; return 1; }
            if declare -F enforce_ownership >/dev/null 2>&1; then
                enforce_ownership "$pre_restore_backup"
            fi
        fi
    fi
    [[ "$simulate" != true ]] && mkdir -p "$target"

        if [[ "$include_app" == true && -n "$app_dir" ]]; then
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would restore application files -> $target"
            else
                log info "[RESTORE] Restoring application files via rsync -> $target"
                if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Restoring app files..." rsync -a "$app_dir"/ "$target"/; then
                    log err "[RESTORE] Failed to restore application files."
                    return 1
                fi
            fi
        elif [[ "$include_app" == true ]]; then
            if [[ "$autofill_app" != "0" ]]; then
                if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would download and install a fresh app because backup lacks app files."
            else
                log warn "[RESTORE] No application directory found in backup. Attempting fresh install (autofill app)."
                local saved_named=("${NAMED_ARGS[@]}")
                # shellcheck disable=SC2154
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
                if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Restoring storage..." rsync -a "$storage_dir"/ "$storage_dest"/; then
                    log warn "[RESTORE] Restoring storage failed."
                fi
            fi
        fi

        if [[ -n "$uploads_dir" ]]; then
            local uploads_dest="$target/public/uploads"
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would restore uploads -> $uploads_dest"
            else
                log info "[RESTORE] Restoring uploads via rsync -> $uploads_dest"
                mkdir -p "$uploads_dest"
                if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Restoring uploads..." rsync -a "$uploads_dir"/ "$uploads_dest"/; then
                    log warn "[RESTORE] Restoring uploads failed."
                fi
            fi
        fi

        if [[ -n "$extra_dir" ]]; then
            local extra_dest="$target/extra"
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would restore extra paths -> $extra_dest"
            else
                log info "[RESTORE] Restoring extra paths via rsync -> $extra_dest"
                mkdir -p "$extra_dest"
                if ! INM_SPINNER_HEARTBEAT=0 spinner_run "Restoring extra paths..." rsync -a "$extra_dir"/ "$extra_dest"/; then
                    log warn "[RESTORE] Restoring extra paths failed."
                fi
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
                        if ! prompt_confirm "RESTORE_NO_APP_KEY" "no" "[RESTORE] Continue without APP_KEY? (yes/no):" false 60; then
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
            local choice=""
            choice="$(prompt_var "RESTORE_DB" "" "Enter SQL file path or 'fresh' (empty to abort):" false 120)" || return 1
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

    if [[ "$simulate" != true ]] && declare -F cleanup_old_backups >/dev/null 2>&1; then
        cleanup_old_backups || log warn "[RESTORE] Backup cleanup failed."
    fi

    local suffix=""
    [[ "$simulate" == true ]] && suffix=" (dry-run)"
    log ok "[RESTORE] Restore flow completed${suffix}."
}
