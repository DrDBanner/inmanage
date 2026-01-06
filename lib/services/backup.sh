#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_BACKUP_LOADED:-} ]] && return
__SERVICE_BACKUP_LOADED=1

# ---------------------------------------------------------------------
# backup_apply_migration_export()
# Update a staged .env with migration-specific values.
# Consumes: args: simulate, env_file; helpers: read_env_value, env_set_file_value, prompt_var, prompt_secret_keep_current.
# Computes: rewrites APP_URL/DB_* and optional extra keys.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
backup_apply_migration_export() {
    local simulate="$1"
    local env_file="$2"
    if [[ "$simulate" == true ]]; then
        log info "[DRY-RUN] Would prompt for migration export values and update $env_file"
        return 0
    fi
    if [[ ! -f "$env_file" ]]; then
        log err "[BACKUP] Migration export requested but .env not found at $env_file"
        return 1
    fi

    log info "[BACKUP] Migration export: updating .env inside backup."
    local current_app_url current_db_host current_db_port current_db_name current_db_user current_db_pass
    current_app_url="$(read_env_value "$env_file" "APP_URL")"
    current_db_host="$(read_env_value "$env_file" "DB_HOST")"
    current_db_port="$(read_env_value "$env_file" "DB_PORT")"
    current_db_name="$(read_env_value "$env_file" "DB_DATABASE")"
    current_db_user="$(read_env_value "$env_file" "DB_USERNAME")"
    current_db_pass="$(read_env_value "$env_file" "DB_PASSWORD")"

    local app_url db_host db_port db_name db_user db_pass
    app_url="$(prompt_var "MIG_APP_URL" "${current_app_url}" "[MIG] APP_URL for target host:" false 120)" || return 1
    db_host="$(prompt_var "MIG_DB_HOST" "${current_db_host:-localhost}" "[MIG] DB_HOST for target host:" false 120)" || return 1
    db_port="$(prompt_var "MIG_DB_PORT" "${current_db_port:-3306}" "[MIG] DB_PORT for target host:" false 120)" || return 1
    db_name="$(prompt_var "MIG_DB_NAME" "${current_db_name}" "[MIG] DB_DATABASE for target host:" false 120)" || return 1
    db_user="$(prompt_var "MIG_DB_USER" "${current_db_user}" "[MIG] DB_USERNAME for target host:" false 120)" || return 1
    db_pass="$(prompt_secret_keep_current "[MIG] DB_PASSWORD for target host:" "$current_db_pass")" || return 1

    env_set_file_value "$env_file" "APP_URL" "$app_url" || return 1
    env_set_file_value "$env_file" "DB_HOST" "$db_host" || return 1
    env_set_file_value "$env_file" "DB_PORT" "$db_port" || return 1
    env_set_file_value "$env_file" "DB_DATABASE" "$db_name" || return 1
    env_set_file_value "$env_file" "DB_USERNAME" "$db_user" || return 1
    env_set_file_value "$env_file" "DB_PASSWORD" "$db_pass" || return 1

    if prompt_confirm "MIG_EXTRA" "no" "[MIG] Add or override more .env keys?" false 120; then
        while true; do
            local extra_key extra_val
            extra_key="$(prompt_var "MIG_EXTRA_KEY" "" "[MIG] Extra key (leave empty to finish):" false 120)" || return 1
            [[ -z "$extra_key" ]] && break
            if [[ "$extra_key" == "APP_KEY" ]]; then
                log warn "[BACKUP] APP_KEY is preserved for migrations; skipping."
                continue
            fi
            extra_val="$(prompt_var "MIG_EXTRA_VAL" "" "[MIG] Value for $extra_key:" false 120)" || return 1
            env_set_file_value "$env_file" "$extra_key" "$extra_val" || return 1
        done
    fi

    log ok "[BACKUP] Migration export complete."
}

# ---------------------------------------------------------------------
# backup_stage_tree()
# Stage a directory into a backup staging area.
# Consumes: args: label, src, dest, missing_label; globals: BACKUP_INCLUDE_APP, BACKUP_INSTALL_REAL, BACKUP_SIMULATE.
# Computes: rsync copy into staging.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
backup_stage_tree() {
    local label="$1"
    local src="$2"
    local dest="$3"
    local missing_label="$4"
    local skip=false
    if [[ "$BACKUP_INCLUDE_APP" == "true" ]] && fs_path_inside_tree "$BACKUP_INSTALL_REAL" "$src"; then
        skip=true
        log debug "[BACKUP] Skipping ${label}: already covered by app copy."
    fi
    if [[ "$skip" != true ]]; then
        if [[ -d "$src" ]]; then
            if [[ "$BACKUP_SIMULATE" == true ]]; then
                log info "[DRY-RUN] Would copy ${label} -> ${dest}"
            else
                fs_sync_dir "$label" "$src" "$dest" "$BACKUP_SIMULATE" normal "BACKUP" || \
                    log warn "[BACKUP] Failed to copy ${label} directory."
            fi
        else
            log warn "[BACKUP] ${missing_label} missing at $src (skipping)."
        fi
    fi
}

# ---------------------------------------------------------------------
# backup_archive_subdir()
# Archive or copy a subdirectory into the backup directory.
# Consumes: args: label, src, rel, target; globals: BACKUP_INCLUDE_APP, BACKUP_INSTALL_REAL, BACKUP_INSTALL_ROOT, BACKUP_COMPRESS, BACKUP_SIMULATE.
# Computes: archive or rsync copy for subdir.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
backup_archive_subdir() {
    local label="$1"
    local src="$2"
    local rel="$3"
    local target="$4"
    local skip=false
    if [[ "$BACKUP_INCLUDE_APP" == "true" ]] && fs_path_inside_tree "$BACKUP_INSTALL_REAL" "$src"; then
        skip=true
        log info "[BACKUP] Skipping ${label}: already covered by app copy."
    fi
    if [[ "$skip" != true && -d "$src" ]]; then
        if [[ "$BACKUP_SIMULATE" == true ]]; then
            log info "[DRY-RUN] Would back up ${label} -> ${target}"
        else
            if [[ "$BACKUP_COMPRESS" == "false" ]]; then
                log info "[BACKUP] Copying ${label} via rsync -> ${target}"
            fi
            log info "[BACKUP] Creating ${label} archive (${BACKUP_COMPRESS}) -> ${target}"
            case "$BACKUP_COMPRESS" in
                tar.gz)
                    spinner_run_mode normal "Archiving ${label}..." tar -czf "$target" -C "$BACKUP_INSTALL_ROOT" "$rel" || \
                        log warn "[BACKUP] Archiving ${label} failed."
                    ;;
                zip)
                    spinner_run_mode normal "Archiving ${label}..." bash -c "cd \"$BACKUP_INSTALL_ROOT\" && zip -r \"$target\" \"$rel\" >/dev/null" || \
                        log warn "[BACKUP] Archiving ${label} failed."
                    ;;
                false)
                    safe_rm_rf "$target" "$BACKUP_DIR"
                    mkdir -p "$target"
                    fs_sync_dir "$label" "$src" "$target" "$BACKUP_SIMULATE" normal "BACKUP" || \
                        log warn "[BACKUP] Copying ${label} failed."
                    ;;
            esac
        fi
        BACKUP_OUTPUTS+=("$target")
    elif [[ "$skip" != true ]]; then
        log warn "[BACKUP] ${label}/ missing at $src (skipping)."
    fi
}

# ---------------------------------------------------------------------
# backup_copy_extra_paths()
# Copy extra paths into a staging target.
# Consumes: args: dest, action; globals: BACKUP_EXTRA_PATHS, BACKUP_INSTALL_ROOT, BACKUP_INCLUDE_APP, BACKUP_INSTALL_REAL, BACKUP_SIMULATE.
# Computes: rsync copy for extra paths.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
backup_copy_extra_paths() {
    local dest="$1"
    local action="$2"
    if [[ ${#BACKUP_EXTRA_PATHS[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ "$BACKUP_SIMULATE" == true ]]; then
        log info "[DRY-RUN] Would copy extra paths -> ${dest} : ${BACKUP_EXTRA_PATHS[*]}"
        return 0
    fi
    mkdir -p "$dest"
    local p
    for p in "${BACKUP_EXTRA_PATHS[@]}"; do
        local resolved
        resolved="$(fs_resolve_relative_path "$BACKUP_INSTALL_ROOT" "$p")"
        if [[ "$BACKUP_INCLUDE_APP" == "true" ]] && fs_path_inside_tree "$BACKUP_INSTALL_REAL" "$resolved"; then
            log info "[BACKUP] Skipping extra path (inside app copy): $resolved"
            continue
        fi
        if [[ -e "$resolved" ]]; then
            log info "[BACKUP] ${action} extra path via rsync -> ${dest}/ (source: $resolved)"
            if ! fs_sync_path "${action} extra path" "$resolved" "$dest" "$BACKUP_SIMULATE" normal "BACKUP"; then
                log warn "[BACKUP] Failed to copy extra path: $resolved"
            fi
        else
            log warn "[BACKUP] Extra path missing, skipping: $resolved"
        fi
    done
}

# ---------------------------------------------------------------------
# backup_archive_env()
# Archive or copy the .env file into the backup.
# Consumes: args: src, target, format, dry_run, apply_migration.
# Computes: archived .env and migration edits if requested.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
backup_archive_env() {
    local src="$1"
    local target="$2"
    local format="$3"
    local dry_run="$4"
    local apply_migration="$5"
    if [[ "$dry_run" == true ]]; then
        log info "[DRY-RUN] Would store .env -> $target (compress=$format)"
        return 0
    fi
    case "$format" in
        tar.gz|zip)
            local env_stage
            env_stage="$(mktemp -d)" || { log err "[BACKUP] Could not create temp dir for .env."; return 1; }
            cp "$src" "$env_stage/.env" || { safe_rm_rf "$env_stage" "$(dirname "$env_stage")"; log warn "[BACKUP] Could not copy .env"; }
            if [[ "$apply_migration" == "true" ]]; then
                backup_apply_migration_export "$dry_run" "$env_stage/.env" || { safe_rm_rf "$env_stage" "$(dirname "$env_stage")"; return 1; }
            fi
            if [[ "$format" == "tar.gz" ]]; then
                tar -czf "$target" -C "$env_stage" ".env" || log warn "[BACKUP] Could not archive .env"
            else
                (cd "$env_stage" && zip -j "$target" ".env") >/dev/null || log warn "[BACKUP] Could not archive .env"
            fi
            safe_rm_rf "$env_stage" "$(dirname "$env_stage")"
            ;;
        false)
            cp "$src" "$target" || log warn "[BACKUP] Could not copy .env"
            if [[ "$apply_migration" == "true" ]]; then
                backup_apply_migration_export "$dry_run" "$target" || return 1
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------
# backup_archive_extras()
# Archive or copy extra paths into the backup.
# Consumes: args: target, format, dry_run; globals: BACKUP_EXTRA_PATHS, BACKUP_DIR.
# Computes: extra paths archive or directory.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
backup_archive_extras() {
    local target="$1"
    local format="$2"
    local dry_run="$3"
    if [[ ${#BACKUP_EXTRA_PATHS[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ "$dry_run" == true ]]; then
        log info "[DRY-RUN] Would back up extra paths -> $target : ${BACKUP_EXTRA_PATHS[*]}"
        return 0
    fi
    case "$format" in
        tar.gz|zip)
            local extra_stage
            extra_stage="$(mktemp -d)" || { log err "[BACKUP] Could not create temp dir for extras."; return 1; }
            backup_copy_extra_paths "$extra_stage" "Staging"
            if [[ "$format" == "tar.gz" ]]; then
                log info "[BACKUP] Creating extra archive (tar.gz) -> $target"
                spinner_run_mode normal "Archiving extras..." tar -czf "$target" -C "$extra_stage" . || log warn "[BACKUP] Archiving extras failed."
            else
                log info "[BACKUP] Creating extra archive (zip) -> $target"
                spinner_run_mode normal "Archiving extras..." bash -c "cd \"$extra_stage\" && zip -r \"$target\" . >/dev/null" || log warn "[BACKUP] Archiving extras failed."
            fi
            safe_rm_rf "$extra_stage" "$(dirname "$extra_stage")"
            ;;
        false)
            safe_rm_rf "$target" "$BACKUP_DIR"
            backup_copy_extra_paths "$target" "Copying"
            ;;
    esac
}

# ---------------------------------------------------------------------
# backup_suffix_for_compress()
# Map compression mode to filename suffix.
# Consumes: args: compress.
# Computes: file extension.
# Returns: prints suffix to stdout.
# ---------------------------------------------------------------------
backup_suffix_for_compress() {
    case "$1" in
        tar.gz) printf ".tar.gz" ;;
        zip) printf ".zip" ;;
        *) printf "" ;;
    esac
}

# ---------------------------------------------------------------------
# run_backup()
# Create backups (db/env/app/storage/uploads/extras) with optional bundle/compress.
# Consumes: args: --compress/--include-app/--extra/--name/...; env: INM_*; helpers: fs_*, env_set_file_value, tar/zip/rsync.
# Computes: backup artifacts in INM_BACKUP_DIRECTORY.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
run_backup() {
    declare -A ARGS
    parse_named_args ARGS "$@"

    local compress="${ARGS[compress]:-tar.gz}"
    local bundle="${ARGS[bundle]:-true}"
    local name="${ARGS[name]:-}"
    local name_provided=false
    if [[ -n "${ARGS[name]+x}" ]]; then
        name_provided=true
    fi
    local include_app="${ARGS[include_app]:-${ARGS[include-app]:-true}}"
    local include_app_explicit=false
    if [[ -n "${ARGS[include_app]+x}" || -n "${ARGS[include-app]+x}" ]]; then
        include_app_explicit=true
    fi
    local db="${ARGS[db]:-true}"
    local storage="${ARGS[storage]:-true}"
    local uploads="${ARGS[uploads]:-true}"
    local fullbackup="${ARGS[fullbackup]:-false}"
    local extra_raw="${ARGS[extra_paths]:-${ARGS[extra]:-}}"
    local create_migration_export="${ARGS[create_migration_export]:-${ARGS[create-migration-export]:-false}}"
    local force="${force_update:-false}"
    local simulate="${DRY_RUN:-false}"
    local backup_dir="${INM_BACKUP_DIRECTORY%/}"
    local backup_dir_mode="${INM_BACKUP_DIR_MODE:-${INM_DIR_MODE:-2750}}"

    case "$compress" in
        tar.gz|zip|false) ;;
        *) log err "[BACKUP] Invalid compress option: $compress"; return 1 ;;
    esac

    if [[ "$fullbackup" == "true" ]]; then
        db=true
        storage=true
        uploads=true
        bundle=true
        [[ "$include_app_explicit" == false ]] && include_app=true
    fi

    local install_root="${INM_INSTALLATION_PATH:-$(compute_installation_path "${INM_BASE_DIRECTORY:-}" "${INM_INSTALLATION_DIRECTORY:-}")}"
    install_root="${install_root%/}"
    if [[ -z "$install_root" ]]; then
        if [[ "$simulate" == true ]]; then
            log err "[DRY-RUN] Would fail: installation path undetermined (INM_INSTALLATION_PATH/INM_BASE_DIRECTORY/INM_INSTALLATION_DIRECTORY)."
            return 0
        fi
        log err "[BACKUP] Could not determine installation path (check INM_INSTALLATION_PATH/INM_BASE_DIRECTORY/INM_INSTALLATION_DIRECTORY)."
        return 1
    fi
    if [[ ! -d "$install_root" ]]; then
        if [[ "$simulate" == true ]]; then
            log warn "[DRY-RUN] Installation path not found (would fail normally): $install_root"
        else
            log err "[BACKUP] Installation path not found: $install_root"
            return 1
        fi
    fi

    run_hook "pre-backup" || return 1

    local env_source="${INM_ENV_FILE:-${install_root}/.env}"
    if [[ "$create_migration_export" == "true" && "$simulate" != true && ! -f "$env_source" ]]; then
        log err "[BACKUP] Migration export requested but .env not found at $env_source"
        return 1
    fi
    local install_real
    install_real=$(realpath "$install_root" 2>/dev/null || echo "$install_root")
    local ts
    ts="$(date +%Y-%m-%d_%H-%M)"
    local base_name=""
    if [[ -z "$name" ]]; then
        base_name="${INM_PROGRAM_NAME:-invoiceninja}_${ts}"
    else
        local append_ts=true
        if [[ "$name_provided" == true && "$name" =~ [0-9]{8}([_-][0-9]{4})? ]]; then
            append_ts=false
        elif [[ "$name_provided" == true && "$name" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
            append_ts=false
        fi
        base_name="${INM_PROGRAM_NAME:-invoiceninja}_${name}"
        if [[ "$append_ts" == true ]]; then
            base_name+="_${ts}"
        fi
    fi
    local app_dir_name
    app_dir_name="$(basename "${INM_INSTALLATION_DIRECTORY:-$install_root}")"

    BACKUP_EXTRA_PATHS=()
    if [[ -n "$extra_raw" ]]; then
        IFS=',' read -ra BACKUP_EXTRA_PATHS <<<"$extra_raw"
    fi

    BACKUP_SIMULATE="$simulate"
    BACKUP_COMPRESS="$compress"
    BACKUP_INCLUDE_APP="$include_app"
    BACKUP_INSTALL_ROOT="$install_root"
    BACKUP_INSTALL_REAL="$install_real"
    BACKUP_DIR="$backup_dir"
    BACKUP_OUTPUTS=()

    log info "[BACKUP] Preparing backup: $base_name"
    log debug "[BACKUP] bundle=${bundle} compress=${compress} db=${db} storage=${storage} uploads=${uploads} include_app=${include_app} extras=${#BACKUP_EXTRA_PATHS[@]} dry-run=${simulate}"

    if [[ "$simulate" != true ]]; then
        mkdir -p "$backup_dir" || {
            log err "[BACKUP] Cannot create backup directory: $backup_dir"
            return 1
        }
    else
        log info "[DRY-RUN] Would ensure backup directory: $backup_dir"
    fi

    # Bundle mode: stage everything and pack once (no nested archives)
    if [[ "$bundle" == "true" ]]; then
        local bundle_path
        bundle_path="$backup_dir/${base_name}$(backup_suffix_for_compress "$compress")"

        local stage=""
        if [[ "$simulate" != true ]]; then
            stage="$(mktemp -d)" || { log err "[BACKUP] Could not create staging directory."; return 1; }
        else
            log info "[DRY-RUN] Would create staging directory for bundle."
            stage="<staging>"
        fi

        if [[ "$db" == "true" ]]; then
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would dump database -> $stage/db.sql"
            else
                log info "[BACKUP] Dumping database..."
                dump_database "$stage/db.sql" || { fs_cleanup_stage "$stage" "$simulate"; return 1; }
            fi
        fi

        if [[ ! -f "$env_source" ]]; then
            if [[ "$force" == true ]]; then
                log warn "[BACKUP] .env not found at $env_source; continuing due to --force."
            else
                log err "[BACKUP] .env not found at $env_source; aborting. Use --force to continue."
                fs_cleanup_stage "$stage" "$simulate"
                return 1
            fi
        else
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would copy $env_source -> $stage/.env"
            else
                if ! cp "$env_source" "$stage/.env"; then
                    if [[ "$force" == true ]]; then
                        log warn "[BACKUP] Failed to copy .env (continuing due to --force)."
                    else
                        log err "[BACKUP] Failed to copy .env into bundle."
                        fs_cleanup_stage "$stage" "$simulate"
                        return 1
                    fi
                fi
            fi
        fi
        if [[ "$create_migration_export" == "true" ]]; then
            backup_apply_migration_export "$simulate" "$stage/.env" || { fs_cleanup_stage "$stage" "$simulate"; return 1; }
        fi

        if [[ "$include_app" == "true" ]]; then
            local app_target="$stage/$app_dir_name"
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would copy app -> $app_target (exclude $(basename "$backup_dir"), .cache)"
            else
                if ! fs_sync_dir "app files" "$install_root" "$app_target" "$simulate" normal "BACKUP" \
                    --delete --exclude "$(basename "$backup_dir")" --exclude ".cache"; then
                    log err "[BACKUP] Failed to stage application directory."
                    fs_cleanup_stage "$stage" "$simulate"
                    return 1
                fi
            fi
        fi

        if [[ "$storage" == "true" ]]; then
            local storage_src="$install_root/storage"
            backup_stage_tree "storage" "$storage_src" "$stage/storage" "storage/"
        fi

        if [[ "$uploads" == "true" ]]; then
            local uploads_src="$install_root/public/uploads"
            backup_stage_tree "uploads" "$uploads_src" "$stage/public/uploads" "uploads/"
        fi

        if [[ ${#BACKUP_EXTRA_PATHS[@]} -gt 0 ]]; then
            backup_copy_extra_paths "$stage/extra" "Staging"
        fi

        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would create bundle at $bundle_path (compress=$compress)"
        else
            log info "[BACKUP] Creating bundle ($compress) at $bundle_path"
            case "$compress" in
                tar.gz)
                spinner_run_mode normal "Creating tar bundle..." tar -czf "$bundle_path" -C "$stage" . || { fs_cleanup_stage "$stage" "$simulate"; log err "[BACKUP] Failed to create tar bundle."; return 1; }
                ;;
            zip)
                spinner_run_mode normal "Creating zip bundle..." bash -c "cd \"$stage\" && zip -r \"$bundle_path\" . >/dev/null" || { fs_cleanup_stage "$stage" "$simulate"; log err "[BACKUP] Failed to create zip bundle."; return 1; }
                ;;
                false)
                    safe_rm_rf "$bundle_path" "$backup_dir"
                    if ! fs_sync_dir "bundle" "$stage" "$bundle_path" "$simulate" normal "BACKUP"; then
                        fs_cleanup_stage "$stage" "$simulate"
                        log err "[BACKUP] Failed to sync bundle directory."
                        return 1
                    fi
                    ;;
            esac
        fi

        fs_cleanup_stage "$stage" "$simulate"

        if [[ "$simulate" != true ]]; then
            enforce_ownership "$backup_dir"
            enforce_permissions "$backup_dir_mode" "$backup_dir"
        else
            log info "[DRY-RUN] Would enforce ownership on backup dir: $backup_dir"
        fi

        if [[ "$simulate" != true && "$compress" != "false" && -f "$bundle_path" ]]; then
            local checksum_target="${bundle_path}.sha256"
            compat_write_sha256_file "$bundle_path" "$checksum_target" && \
                log ok "[BACKUP] Checksum written: $checksum_target"
        elif [[ "$simulate" == true && "$compress" != "false" ]]; then
            log info "[DRY-RUN] Would create checksum for $bundle_path"
        fi

        local bundle_size=""
        if [[ "$simulate" != true && -e "$bundle_path" ]]; then
            bundle_size="$(fs_path_size "$bundle_path")"
        fi
        if [[ -n "$bundle_size" ]]; then
            log ok "[BACKUP] Bundle ready: $bundle_path (Size: $bundle_size)"
        else
            log ok "[BACKUP] Bundle ready: $bundle_path"
        fi
        run_hook "post-backup" || return 1
        return 0
    fi

    # Multi-part mode (no bundle)

    if [[ "$db" == "true" ]]; then
        local db_file="$backup_dir/${base_name}_db.sql"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would dump database -> $db_file"
        else
            log info "[BACKUP] Dumping database..."
            dump_database "$db_file" || return 1
        fi
        BACKUP_OUTPUTS+=("$db_file")
    fi

    # .env is mandatory unless --force
    local env_target
    env_target="$backup_dir/${base_name}_env$(backup_suffix_for_compress "$compress")"

    if [[ ! -f "$env_source" ]]; then
        if [[ "$force" == true ]]; then
            log warn "[BACKUP] .env not found at $env_source; continuing due to --force."
        else
            log err "[BACKUP] .env not found at $env_source; aborting. Use --force to continue."
            return 1
        fi
    else
        backup_archive_env "$env_source" "$env_target" "$compress" "$simulate" "$create_migration_export" || return 1
        [[ "$simulate" == true || -f "$env_target" ]] && BACKUP_OUTPUTS+=("$env_target")
    fi

    if [[ "$storage" == "true" ]]; then
        local storage_src="$install_root/storage"
        local storage_target
        storage_target="$backup_dir/${base_name}_storage$(backup_suffix_for_compress "$compress")"
        backup_archive_subdir "storage" "$storage_src" "storage" "$storage_target"
    fi

    if [[ "$uploads" == "true" ]]; then
        local uploads_src="$install_root/public/uploads"
        local uploads_target
        uploads_target="$backup_dir/${base_name}_uploads$(backup_suffix_for_compress "$compress")"
        backup_archive_subdir "uploads" "$uploads_src" "public/uploads" "$uploads_target"
    fi

    if [[ "$include_app" == "true" ]]; then
        local app_target
        app_target="$backup_dir/${base_name}_app$(backup_suffix_for_compress "$compress")"

        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would back up app -> $app_target (exclude $(basename "$backup_dir"), .cache)"
        else
            if [[ "$compress" == "false" ]]; then
                log info "[BACKUP] Copying app via rsync -> $app_target"
            fi
            log info "[BACKUP] Creating app archive ($compress) -> $app_target"
            case "$compress" in
                tar.gz)
                    spinner_run_mode normal "Archiving app..." tar -czf "$app_target" -C "$(dirname "$install_root")" --exclude "$(basename "$backup_dir")" --exclude ".cache" "$(basename "$install_root")" || log warn "[BACKUP] Archiving app failed."
                    ;;
                zip)
                    spinner_run_mode normal "Archiving app..." bash -c "cd \"$(dirname "$install_root")\" && zip -r \"$app_target\" \"$(basename "$install_root")\" -x \"$(basename "$backup_dir")/*\" \".cache/*\" >/dev/null" || log warn "[BACKUP] Archiving app failed."
                    ;;
                false)
                    safe_rm_rf "$app_target" "$backup_dir"
                    fs_sync_dir "app files" "$install_root" "$app_target" "$simulate" normal "BACKUP" \
                        --exclude "$(basename "$backup_dir")" --exclude ".cache" || log warn "[BACKUP] Copying app failed."
                    ;;
            esac
        fi
        BACKUP_OUTPUTS+=("$app_target")
    fi

        if [[ ${#BACKUP_EXTRA_PATHS[@]} -gt 0 ]]; then
            local extra_target
            extra_target="$backup_dir/${base_name}_extra$(backup_suffix_for_compress "$compress")"
            backup_archive_extras "$extra_target" "$compress" "$simulate" || return 1
            BACKUP_OUTPUTS+=("$extra_target")
        fi

    if [[ "$simulate" == true ]]; then
        log info "[DRY-RUN] Would write checksums for files (skip directories) among: ${BACKUP_OUTPUTS[*]}"
    else
        for f in "${BACKUP_OUTPUTS[@]}"; do
            if [[ -f "$f" ]]; then
                local cfile="${f}.sha256"
                compat_write_sha256_file "$f" "$cfile" && log ok "[BACKUP] Checksum written: $cfile"
            fi
        done
        enforce_ownership "$backup_dir"
        enforce_permissions "$backup_dir_mode" "$backup_dir"
    fi

    log ok "[BACKUP] Backup completed (multi-part). Base: $base_name"
    for f in "${BACKUP_OUTPUTS[@]}"; do
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Planned output: $f"
        elif [[ -e "$f" ]]; then
            log info "[BACKUP] Output: $f"
        fi
    done
    run_hook "post-backup" || return 1
}
