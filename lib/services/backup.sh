#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_BACKUP_LOADED:-} ]] && return
__SERVICE_BACKUP_LOADED=1

# Creates backups (DB/env/app/storage/uploads/extra) with optional bundling/compression.
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

    if declare -F run_hook >/dev/null 2>&1; then
        run_hook "pre-backup" || return 1
    fi

    local env_source="${INM_ENV_FILE:-${install_root}/.env}"
    if [[ "$create_migration_export" == "true" && "$simulate" != true && ! -f "$env_source" ]]; then
        log err "[BACKUP] Migration export requested but .env not found at $env_source"
        return 1
    fi
    local install_real
    install_real=$(realpath "$install_root" 2>/dev/null || echo "$install_root")
    path_inside_app_tree() {
        local src="$1"
        [[ ! -e "$src" || -L "$src" ]] && return 1
        local src_real
        src_real=$(realpath "$src" 2>/dev/null || echo "$src")
        [[ "$src_real" == "$install_real"/* ]]
    }
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

    local extra_paths=()
    if [[ -n "$extra_raw" ]]; then
        IFS=',' read -ra extra_paths <<<"$extra_raw"
    fi

    log info "[BACKUP] Preparing backup: $base_name"
    log debug "[BACKUP] bundle=${bundle} compress=${compress} db=${db} storage=${storage} uploads=${uploads} include_app=${include_app} extras=${#extra_paths[@]} dry-run=${simulate}"

    if [[ "$simulate" != true ]]; then
        mkdir -p "$backup_dir" || {
            log err "[BACKUP] Cannot create backup directory: $backup_dir"
            return 1
        }
    else
        log info "[DRY-RUN] Would ensure backup directory: $backup_dir"
    fi

    # Helper to resolve extra paths relative to install_root when not absolute
    resolve_extra_path() {
        local p="$1"
        if [[ "$p" == /* ]]; then
            printf "%s\n" "$p"
        else
            printf "%s/%s\n" "$install_root" "${p#/}"
        fi
    }

    get_path_size() {
        local p="$1"
        if command -v du >/dev/null 2>&1; then
            du -sh "$p" 2>/dev/null | awk '{print $1}'
        fi
    }

    set_env_value() {
        local file="$1"
        local key="$2"
        local value="$3"
        if declare -F env_set >/dev/null 2>&1; then
            INM_ENV_FILE="$file" env_set app "${key}=${value}" >/dev/null || return 1
        else
            log err "[BACKUP] env_set helper missing; cannot update $key in $file"
            return 1
        fi
    }

    run_with_spinner() {
        local msg="$1"
        shift
        if declare -F spinner_run_optional >/dev/null 2>&1; then
            spinner_run_optional "$msg" "$@"
        elif declare -F spinner_run >/dev/null 2>&1; then
            spinner_run "$msg" "$@"
        else
            "$@"
        fi
    }

    apply_migration_export() {
        local env_file="$1"
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

        set_env_value "$env_file" "APP_URL" "$app_url" || return 1
        set_env_value "$env_file" "DB_HOST" "$db_host" || return 1
        set_env_value "$env_file" "DB_PORT" "$db_port" || return 1
        set_env_value "$env_file" "DB_DATABASE" "$db_name" || return 1
        set_env_value "$env_file" "DB_USERNAME" "$db_user" || return 1
        set_env_value "$env_file" "DB_PASSWORD" "$db_pass" || return 1

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
                set_env_value "$env_file" "$extra_key" "$extra_val" || return 1
            done
        fi

        log ok "[BACKUP] Migration export complete."
    }

    # Bundle mode: stage everything and pack once (no nested archives)
    if [[ "$bundle" == "true" ]]; then
        local bundle_path="$backup_dir/${base_name}"
        [[ "$compress" == "tar.gz" ]] && bundle_path+=".tar.gz"
        [[ "$compress" == "zip" ]] && bundle_path+=".zip"

        local stage=""
        if [[ "$simulate" != true ]]; then
            stage="$(mktemp -d)" || { log err "[BACKUP] Could not create staging directory."; return 1; }
        else
            log info "[DRY-RUN] Would create staging directory for bundle."
            stage="<staging>"
        fi

        cleanup_stage() {
            [[ "$simulate" != true && -n "$stage" && -d "$stage" ]] && safe_rm_rf "$stage" "$(dirname "$stage")"
        }

        if [[ "$db" == "true" ]]; then
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would dump database -> $stage/db.sql"
            else
                log info "[BACKUP] Dumping database..."
                dump_database "$stage/db.sql" || { cleanup_stage; return 1; }
            fi
        fi

        if [[ ! -f "$env_source" ]]; then
            if [[ "$force" == true ]]; then
                log warn "[BACKUP] .env not found at $env_source; continuing due to --force."
            else
                log err "[BACKUP] .env not found at $env_source; aborting. Use --force to continue."
                cleanup_stage
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
                        cleanup_stage
                        return 1
                    fi
                fi
            fi
        fi
        if [[ "$create_migration_export" == "true" ]]; then
            apply_migration_export "$stage/.env" || { cleanup_stage; return 1; }
        fi

            if [[ "$include_app" == "true" ]]; then
                local app_target="$stage/$app_dir_name"
                if [[ "$simulate" == true ]]; then
                    log info "[DRY-RUN] Would copy app -> $app_target (exclude $(basename "$backup_dir"), .cache)"
                else
                    log info "[BACKUP] Staging app via rsync -> $app_target"
                    mkdir -p "$app_target"
                    run_with_spinner "Staging app files..." rsync -a --delete --exclude "$(basename "$backup_dir")" --exclude ".cache" "$install_root/." "$app_target/" || {
                        log err "[BACKUP] Failed to stage application directory."
                        cleanup_stage
                        return 1
                    }
                fi
            fi

        if [[ "$storage" == "true" ]]; then
            local storage_src="$install_root/storage"
            local skip_storage=false
            if [[ "$include_app" == "true" ]] && path_inside_app_tree "$storage_src"; then
                skip_storage=true
                log debug "[BACKUP] Skipping storage: already covered by app copy."
            fi
            if [[ "$skip_storage" != true ]]; then
                if [[ -d "$storage_src" ]]; then
                    if [[ "$simulate" == true ]]; then
                        log info "[DRY-RUN] Would copy storage -> $stage/storage/"
                    else
                        log info "[BACKUP] Staging storage via rsync -> $stage/storage/"
                        mkdir -p "$stage/storage"
                        if ! run_with_spinner "Staging storage..." rsync -a "$storage_src/." "$stage/storage/"; then
                            log warn "[BACKUP] Failed to copy storage directory."
                        fi
                    fi
                else
                    log warn "[BACKUP] storage/ missing at $storage_src (skipping)."
                fi
            fi
        fi

        if [[ "$uploads" == "true" ]]; then
            local uploads_src="$install_root/public/uploads"
            local skip_uploads=false
            if [[ "$include_app" == "true" ]] && path_inside_app_tree "$uploads_src"; then
                skip_uploads=true
                log debug "[BACKUP] Skipping uploads: already covered by app copy."
            fi
            if [[ "$skip_uploads" != true ]]; then
                if [[ -d "$uploads_src" ]]; then
                    if [[ "$simulate" == true ]]; then
                        log info "[DRY-RUN] Would copy uploads -> $stage/public/uploads/"
                    else
                        log info "[BACKUP] Staging uploads via rsync -> $stage/public/uploads/"
                        mkdir -p "$stage/public/uploads"
                        if ! run_with_spinner "Staging uploads..." rsync -a "$uploads_src/." "$stage/public/uploads/"; then
                            log warn "[BACKUP] Failed to copy uploads directory."
                        fi
                    fi
                else
                    log warn "[BACKUP] uploads/ missing at $uploads_src (skipping)."
                fi
            fi
        fi

            if [[ ${#extra_paths[@]} -gt 0 ]]; then
                if [[ "$simulate" == true ]]; then
                    log info "[DRY-RUN] Would copy extra paths -> $stage/extra/: ${extra_paths[*]}"
                else
                    mkdir -p "$stage/extra"
                    for p in "${extra_paths[@]}"; do
                        local resolved
                        resolved="$(resolve_extra_path "$p")"
                        if [[ "$include_app" == "true" ]]; then
                            if path_inside_app_tree "$resolved"; then
                                log info "[BACKUP] Skipping extra path (inside app copy): $resolved"
                                continue
                            fi
                        fi
                        if [[ -e "$resolved" ]]; then
                            log info "[BACKUP] Staging extra path via rsync -> $stage/extra/ (source: $resolved)"
                            run_with_spinner "Staging extra path..." rsync -a "$resolved" "$stage/extra/" || log warn "[BACKUP] Failed to copy extra path: $resolved"
                        else
                            log warn "[BACKUP] Extra path missing, skipping: $resolved"
                        fi
                    done
            fi
        fi

        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would create bundle at $bundle_path (compress=$compress)"
        else
            log info "[BACKUP] Creating bundle ($compress) at $bundle_path"
            case "$compress" in
                tar.gz)
                run_with_spinner "Creating tar bundle..." tar -czf "$bundle_path" -C "$stage" . || { cleanup_stage; log err "[BACKUP] Failed to create tar bundle."; return 1; }
                ;;
            zip)
                run_with_spinner "Creating zip bundle..." bash -c "cd \"$stage\" && zip -r \"$bundle_path\" . >/dev/null" || { cleanup_stage; log err "[BACKUP] Failed to create zip bundle."; return 1; }
                ;;
                false)
                    safe_rm_rf "$bundle_path" "$backup_dir"
                    if ! rsync -a "$stage"/ "$bundle_path"/; then
                        cleanup_stage
                        log err "[BACKUP] Failed to sync bundle directory."
                        return 1
                    fi
                    ;;
            esac
        fi

        cleanup_stage

        if [[ "$simulate" != true ]]; then
            enforce_ownership "$backup_dir"
        else
            log info "[DRY-RUN] Would enforce ownership on backup dir: $backup_dir"
        fi

        if [[ "$simulate" != true && "$compress" != "false" && -f "$bundle_path" ]]; then
            local checksum_target="${bundle_path}.sha256"
            if declare -F compat_write_sha256_file >/dev/null 2>&1; then
                compat_write_sha256_file "$bundle_path" "$checksum_target" && \
                    log ok "[BACKUP] Checksum written: $checksum_target"
            else
                (cd "$backup_dir" && sha256sum "$(basename "$bundle_path")" > "$(basename "$checksum_target")") && \
                    log ok "[BACKUP] Checksum written: $checksum_target"
            fi
        elif [[ "$simulate" == true && "$compress" != "false" ]]; then
            log info "[DRY-RUN] Would create checksum for $bundle_path"
        fi

        local bundle_size=""
        if [[ "$simulate" != true && -e "$bundle_path" ]]; then
            bundle_size="$(get_path_size "$bundle_path")"
        fi
        if [[ -n "$bundle_size" ]]; then
            log ok "[BACKUP] Bundle ready: $bundle_path (Size: $bundle_size)"
        else
            log ok "[BACKUP] Bundle ready: $bundle_path"
        fi
        if declare -F run_hook >/dev/null 2>&1; then
            run_hook "post-backup" || return 1
        fi
        return 0
    fi

    # Multi-part mode (no bundle)
    local outputs=()

    if [[ "$db" == "true" ]]; then
        local db_file="$backup_dir/${base_name}_db.sql"
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would dump database -> $db_file"
        else
            log info "[BACKUP] Dumping database..."
            dump_database "$db_file" || return 1
        fi
        outputs+=("$db_file")
    fi

    # .env is mandatory unless --force
    local env_target="$backup_dir/${base_name}_env"
    case "$compress" in
        tar.gz) env_target+=".tar.gz" ;;
        zip) env_target+=".zip" ;;
        false) ;; # keep as-is
    esac

    if [[ ! -f "$env_source" ]]; then
        if [[ "$force" == true ]]; then
            log warn "[BACKUP] .env not found at $env_source; continuing due to --force."
        else
            log err "[BACKUP] .env not found at $env_source; aborting. Use --force to continue."
            return 1
        fi
    else
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would store .env -> $env_target (compress=$compress)"
        else
            case "$compress" in
                tar.gz)
                    local env_stage
                    env_stage="$(mktemp -d)" || { log err "[BACKUP] Could not create temp dir for .env."; return 1; }
                    cp "$env_source" "$env_stage/.env" || { safe_rm_rf "$env_stage" "$(dirname "$env_stage")"; log warn "[BACKUP] Could not copy .env"; }
                    if [[ "$create_migration_export" == "true" ]]; then
                        apply_migration_export "$env_stage/.env" || { safe_rm_rf "$env_stage" "$(dirname "$env_stage")"; return 1; }
                    fi
                    tar -czf "$env_target" -C "$env_stage" ".env" || log warn "[BACKUP] Could not archive .env"
                    safe_rm_rf "$env_stage" "$(dirname "$env_stage")"
                    ;;
                zip)
                    local env_stage
                    env_stage="$(mktemp -d)" || { log err "[BACKUP] Could not create temp dir for .env."; return 1; }
                    cp "$env_source" "$env_stage/.env" || { safe_rm_rf "$env_stage" "$(dirname "$env_stage")"; log warn "[BACKUP] Could not copy .env"; }
                    if [[ "$create_migration_export" == "true" ]]; then
                        apply_migration_export "$env_stage/.env" || { safe_rm_rf "$env_stage" "$(dirname "$env_stage")"; return 1; }
                    fi
                    (cd "$env_stage" && zip -j "$env_target" ".env") >/dev/null || log warn "[BACKUP] Could not archive .env"
                    safe_rm_rf "$env_stage" "$(dirname "$env_stage")"
                    ;;
                false)
                    cp "$env_source" "$env_target" || log warn "[BACKUP] Could not copy .env"
                    if [[ "$create_migration_export" == "true" ]]; then
                        apply_migration_export "$env_target" || return 1
                    fi
                    ;;
            esac
        fi
        [[ "$simulate" == true || -f "$env_target" ]] && outputs+=("$env_target")
    fi

    if [[ "$storage" == "true" ]]; then
        local storage_src="$install_root/storage"
        local storage_target="$backup_dir/${base_name}_storage"
        if [[ "$compress" == "tar.gz" ]]; then storage_target+=".tar.gz"; fi
        if [[ "$compress" == "zip" ]]; then storage_target+=".zip"; fi

        local skip_storage=false
        if [[ "$include_app" == "true" ]] && path_inside_app_tree "$storage_src"; then
            skip_storage=true
            log info "[BACKUP] Skipping storage: already covered by app copy."
        fi

        if [[ "$skip_storage" != true && -d "$storage_src" ]]; then
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would back up storage -> $storage_target"
            else
                if [[ "$compress" == "false" ]]; then
                    log info "[BACKUP] Copying storage via rsync -> $storage_target"
                fi
                log info "[BACKUP] Creating storage archive ($compress) -> $storage_target"
                case "$compress" in
                tar.gz)
                        run_with_spinner "Archiving storage..." tar -czf "$storage_target" -C "$install_root" storage || { log err "[BACKUP] Archiving storage failed."; return 1; }
                        ;;
                    zip)
                        run_with_spinner "Archiving storage..." bash -c "cd \"$install_root\" && zip -r \"$storage_target\" storage >/dev/null" || { log err "[BACKUP] Archiving storage failed."; return 1; }
                        ;;
                    false)
                        safe_rm_rf "$storage_target" "$backup_dir"
                        mkdir -p "$storage_target"
                        run_with_spinner "Copying storage..." rsync -a "$storage_src/." "$storage_target/" || { log err "[BACKUP] Copying storage failed."; return 1; }
                        ;;
                esac
            fi
            outputs+=("$storage_target")
        elif [[ "$skip_storage" != true ]]; then
            log warn "[BACKUP] storage/ missing at $storage_src (skipping)."
        fi
    fi

    if [[ "$uploads" == "true" ]]; then
        local uploads_src="$install_root/public/uploads"
        local uploads_target="$backup_dir/${base_name}_uploads"
        if [[ "$compress" == "tar.gz" ]]; then uploads_target+=".tar.gz"; fi
        if [[ "$compress" == "zip" ]]; then uploads_target+=".zip"; fi

        local skip_uploads=false
        if [[ "$include_app" == "true" ]] && path_inside_app_tree "$uploads_src"; then
            skip_uploads=true
            log info "[BACKUP] Skipping uploads: already covered by app copy."
        fi

        if [[ "$skip_uploads" != true && -d "$uploads_src" ]]; then
            if [[ "$simulate" == true ]]; then
                log info "[DRY-RUN] Would back up uploads -> $uploads_target"
            else
                if [[ "$compress" == "false" ]]; then
                    log info "[BACKUP] Copying uploads via rsync -> $uploads_target"
                fi
                log info "[BACKUP] Creating uploads archive ($compress) -> $uploads_target"
                case "$compress" in
                tar.gz)
                        run_with_spinner "Archiving uploads..." tar -czf "$uploads_target" -C "$install_root" public/uploads || log warn "[BACKUP] Archiving uploads failed."
                        ;;
                    zip)
                        run_with_spinner "Archiving uploads..." bash -c "cd \"$install_root\" && zip -r \"$uploads_target\" public/uploads >/dev/null" || log warn "[BACKUP] Archiving uploads failed."
                        ;;
                    false)
                        safe_rm_rf "$uploads_target" "$backup_dir"
                        mkdir -p "$uploads_target"
                        run_with_spinner "Copying uploads..." rsync -a "$uploads_src/." "$uploads_target/" || log warn "[BACKUP] Copying uploads failed."
                        ;;
                esac
            fi
            outputs+=("$uploads_target")
        elif [[ "$skip_uploads" != true ]]; then
            log warn "[BACKUP] uploads/ missing at $uploads_src (skipping)."
        fi
    fi

    if [[ "$include_app" == "true" ]]; then
        local app_target="$backup_dir/${base_name}_app"
        if [[ "$compress" == "tar.gz" ]]; then app_target+=".tar.gz"; fi
        if [[ "$compress" == "zip" ]]; then app_target+=".zip"; fi

        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would back up app -> $app_target (exclude $(basename "$backup_dir"), .cache)"
        else
            if [[ "$compress" == "false" ]]; then
                log info "[BACKUP] Copying app via rsync -> $app_target"
            fi
            log info "[BACKUP] Creating app archive ($compress) -> $app_target"
            case "$compress" in
                tar.gz)
                    run_with_spinner "Archiving app..." tar -czf "$app_target" -C "$(dirname "$install_root")" --exclude "$(basename "$backup_dir")" --exclude ".cache" "$(basename "$install_root")" || log warn "[BACKUP] Archiving app failed."
                    ;;
                zip)
                    run_with_spinner "Archiving app..." bash -c "cd \"$(dirname "$install_root")\" && zip -r \"$app_target\" \"$(basename "$install_root")\" -x \"$(basename "$backup_dir")/*\" \".cache/*\" >/dev/null" || log warn "[BACKUP] Archiving app failed."
                    ;;
                false)
                    safe_rm_rf "$app_target" "$backup_dir"
                    mkdir -p "$app_target"
                        run_with_spinner "Copying app files..." rsync -a --exclude "$(basename "$backup_dir")" --exclude ".cache" "$install_root/." "$app_target/" || log warn "[BACKUP] Copying app failed."
                    ;;
            esac
        fi
        outputs+=("$app_target")
    fi

        if [[ ${#extra_paths[@]} -gt 0 ]]; then
            local extra_target="$backup_dir/${base_name}_extra"
            [[ "$compress" == "tar.gz" ]] && extra_target+=".tar.gz"
            [[ "$compress" == "zip" ]] && extra_target+=".zip"

        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Would back up extra paths -> $extra_target : ${extra_paths[*]}"
        else
            case "$compress" in
                tar.gz|zip)
                    local extra_stage
                    extra_stage="$(mktemp -d)" || { log err "[BACKUP] Could not create temp dir for extras."; return 1; }
                    for p in "${extra_paths[@]}"; do
                        local resolved
                        resolved="$(resolve_extra_path "$p")"
                        if [[ "$include_app" == "true" ]] && path_inside_app_tree "$resolved"; then
                            log info "[BACKUP] Skipping extra path (inside app copy): $resolved"
                            continue
                        fi
                        if [[ -e "$resolved" ]]; then
                            log info "[BACKUP] Staging extra path via rsync -> $extra_stage/ (source: $resolved)"
                            run_with_spinner "Staging extra path..." rsync -a "$resolved" "$extra_stage/" || log warn "[BACKUP] Failed to copy extra path: $resolved"
                        else
                            log warn "[BACKUP] Extra path missing, skipping: $resolved"
                        fi
                    done
                    if [[ "$compress" == "tar.gz" ]]; then
                        log info "[BACKUP] Creating extra archive (tar.gz) -> $extra_target"
                        run_with_spinner "Archiving extras..." tar -czf "$extra_target" -C "$extra_stage" . || log warn "[BACKUP] Archiving extras failed."
                    else
                        log info "[BACKUP] Creating extra archive (zip) -> $extra_target"
                        run_with_spinner "Archiving extras..." bash -c "cd \"$extra_stage\" && zip -r \"$extra_target\" . >/dev/null" || log warn "[BACKUP] Archiving extras failed."
                    fi
                    safe_rm_rf "$extra_stage" "$(dirname "$extra_stage")"
                    ;;
                false)
                    safe_rm_rf "$extra_target" "$backup_dir"
                    mkdir -p "$extra_target"
                    for p in "${extra_paths[@]}"; do
                        local resolved
                        resolved="$(resolve_extra_path "$p")"
                        if [[ "$include_app" == "true" ]] && path_inside_app_tree "$resolved"; then
                            log info "[BACKUP] Skipping extra path (inside app copy): $resolved"
                            continue
                        fi
                        if [[ -e "$resolved" ]]; then
                            log info "[BACKUP] Copying extra path via rsync -> $extra_target/ (source: $resolved)"
                        run_with_spinner "Copying extra path..." rsync -a "$resolved" "$extra_target/" || log warn "[BACKUP] Failed to copy extra path: $resolved"
                        else
                            log warn "[BACKUP] Extra path missing, skipping: $resolved"
                        fi
                    done
                    ;;
            esac
        fi
        outputs+=("$extra_target")
    fi

    if [[ "$simulate" == true ]]; then
        log info "[DRY-RUN] Would write checksums for files (skip directories) among: ${outputs[*]}"
    else
        for f in "${outputs[@]}"; do
            if [[ -f "$f" ]]; then
                local cfile="${f}.sha256"
                if declare -F compat_write_sha256_file >/dev/null 2>&1; then
                    compat_write_sha256_file "$f" "$cfile" && log ok "[BACKUP] Checksum written: $cfile"
                else
                    (cd "$(dirname "$f")" && sha256sum "$(basename "$f")" > "$(basename "$cfile")") && \
                        log ok "[BACKUP] Checksum written: $cfile"
                fi
            fi
        done
        enforce_ownership "$backup_dir"
        enforce_permissions 750 "$backup_dir"
    fi

    log ok "[BACKUP] Backup completed (multi-part). Base: $base_name"
    for f in "${outputs[@]}"; do
        if [[ "$simulate" == true ]]; then
            log info "[DRY-RUN] Planned output: $f"
        elif [[ -e "$f" ]]; then
            log info "[BACKUP] Output: $f"
        fi
    done
    if declare -F run_hook >/dev/null 2>&1; then
        run_hook "post-backup" || return 1
    fi
}
