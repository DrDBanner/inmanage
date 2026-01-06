#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_CLEANUP_LOADED:-} ]] && return
__SERVICE_CLEANUP_LOADED=1

# ---------------------------------------------------------------------
# cleanup_old_versions()
# Remove old update and rollback directories.
# Consumes: env: INM_INSTALLATION_PATH, INM_INSTALLATION_DIRECTORY, INM_KEEP_BACKUPS; deps: safe_rm_rf.
# Computes: directory cleanup for old versions.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
cleanup_old_versions() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cleanup of old versions."
        return 0
    fi
    log debug "[COV] Cleaning up old update directory versions."
    local update_dirs
    local rollback_dirs
    local install_parent
    local install_name
    local keep="${INM_KEEP_BACKUPS:-2}"
    install_parent="$(dirname "${INM_INSTALLATION_PATH%/}")"
    install_name="$(basename "${INM_INSTALLATION_PATH%/}")"
    if [ -z "$install_name" ] || [ "$install_name" = "." ]; then
        install_name="$(basename "${INM_INSTALLATION_DIRECTORY}")"
    fi

    update_dirs=$(find "$install_parent" -maxdepth 1 -type d -name "${install_name}_*" ! -name "${install_name}_rollback_*" 2>/dev/null | sort -r | tail -n +$((keep + 1)))
    rollback_dirs=$(find "$install_parent" -maxdepth 1 -type d -name "${install_name}_rollback_*" 2>/dev/null | sort -r | tail -n +$((keep + 1)))

    if [ -n "$update_dirs" ]; then
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            safe_rm_rf "$dir" "$install_parent" || {
                log err "[COV] Failed to clean up old versions."
                exit 1
            }
        done <<< "$update_dirs"
    fi
    if [ -n "$rollback_dirs" ]; then
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            safe_rm_rf "$dir" "$install_parent" || {
                log err "[COV] Failed to clean up old rollbacks."
                exit 1
            }
        done <<< "$rollback_dirs"
    fi
}

# ---------------------------------------------------------------------
# cleanup_old_backups()
# Remove old backup files based on retention rules.
# Consumes: env: INM_BASE_DIRECTORY, INM_BACKUP_DIRECTORY, INM_KEEP_BACKUPS; globals: NAMED_ARGS.
# Computes: backup pruning with optional stats.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
cleanup_old_backups() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cleanup of old backups."
        return 0
    fi
    log debug "[COB] Cleaning up old backups."
    local backup_path="$INM_BASE_DIRECTORY$INM_BACKUP_DIRECTORY"
    local keep="${INM_KEEP_BACKUPS:-2}"
    local -A type_items=()
    local -A type_seen=()
    local -A keep_set=()
    local -A sidecars=()
    local -a all_items=()
    local stats=false
    local fast=false

    if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[stats]:-false}" == true || "${NAMED_ARGS[stats]:-}" == "true" ]]; then
        stats=true
    fi
    if [[ "${NAMED_ARGS[fast]:-false}" == true || "${NAMED_ARGS[fast]:-}" == "true" ]]; then
        fast=true
    fi

    human_size_kb() {
        local kb="$1"
        local units=(K M G T P)
        local idx=0
        local val="$kb"
        if [[ -z "$kb" || "$kb" -le 0 ]]; then
            printf "0K"
            return 0
        fi
        while [[ "$val" -ge 1024 && "$idx" -lt 4 ]]; do
            val=$((val / 1024))
            idx=$((idx + 1))
        done
        printf "%s%s" "$val" "${units[$idx]}"
    }

    backup_item_type() {
        local name="$1"
        local base="$name"
        base="${base%.sha256}"
        base="${base%.tar.gz}"
        base="${base%.tgz}"
        base="${base%.zip}"
        base="${base%.sql}"
        if [[ "$name" == restore_pre_* ]]; then
            echo "restore_pre"
        elif [[ "$base" == *_preimport_* ]]; then
            echo "preimport"
        elif [[ "$base" == *_preprovision_* ]]; then
            echo "preprovision"
        elif [[ "$base" == *_rollback_*_db ]]; then
            echo "rollback_db"
        elif [[ "$base" == *_db ]]; then
            echo "db"
        elif [[ "$base" == *_env ]]; then
            echo "env"
        elif [[ "$base" == *_storage ]]; then
            echo "storage"
        elif [[ "$base" == *_uploads ]]; then
            echo "uploads"
        elif [[ "$base" == *_app ]]; then
            echo "app"
        elif [[ "$base" == *_extra ]]; then
            echo "extra"
        elif [[ "$name" == *.tar.gz || "$name" == *.tgz || "$name" == *.zip ]]; then
            echo "bundle"
        else
            echo "other"
        fi
    }

    if [ -d "$backup_path" ]; then
        local resolved_backup resolved_base resolved_install
        resolved_backup="$(realpath "$backup_path" 2>/dev/null || echo "$backup_path")"
        resolved_base="$(realpath "${INM_BASE_DIRECTORY:-}" 2>/dev/null || echo "${INM_BASE_DIRECTORY:-}")"
        resolved_install="$(realpath "${INM_INSTALLATION_PATH:-}" 2>/dev/null || echo "${INM_INSTALLATION_PATH:-}")"
        if [[ -z "$resolved_backup" || "$resolved_backup" == "/" || "$resolved_backup" == "." || "$resolved_backup" == ".." ]]; then
            log err "[COB] Refusing to clean backups with unsafe path: ${backup_path:-<empty>}"
            return 1
        fi
        if [[ -n "$resolved_base" && "$resolved_backup" == "$resolved_base" ]]; then
            log err "[COB] Refusing to clean backups: backup dir equals base dir ($resolved_backup)."
            return 1
        fi
        if [[ -n "$resolved_install" && "$resolved_backup" == "$resolved_install" ]]; then
            log err "[COB] Refusing to clean backups: backup dir equals app dir ($resolved_backup)."
            return 1
        fi
        while IFS= read -r -d '' item; do
            local name
            name="$(basename "$item")"
            all_items+=("$item")
            if [[ "$name" == *.sha256 ]]; then
                local base_path="${item%.sha256}"
                sidecars["$base_path"]="$item"
                continue
            fi
            local item_type
            item_type="$(backup_item_type "$name")"
            type_items["$item_type"]+="${item}"$'\n'
            type_seen["$item_type"]=1
        done < <(find "$backup_path" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -print0 2>/dev/null)
    fi

    local t
    for t in "${!type_seen[@]}"; do
        local items="${type_items[$t]}"
        [[ -z "$items" ]] && continue
        mapfile -t sorted < <(printf '%s' "$items" | sort -r)
        local count=0
        local item
        for item in "${sorted[@]}"; do
            [[ -z "$item" ]] && continue
            count=$((count + 1))
            if [ "$count" -le "$keep" ]; then
                keep_set["$item"]=1
            fi
        done
    done

    local kept
    for kept in "${!keep_set[@]}"; do
        if [[ -n "${sidecars[$kept]:-}" ]]; then
            keep_set["${sidecars[$kept]}"]=1
        fi
    done

    local item
    local -a to_remove=()
    for item in "${all_items[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ -z "${keep_set[$item]:-}" ]]; then
            to_remove+=("$item")
        fi
    done

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        log debug "[COB] No backup items to clean."
        return 0
    fi

    if [[ "$stats" == true ]]; then
        local total_kb=0
        local size_kb
        for item in "${to_remove[@]}"; do
            [[ -e "$item" ]] || continue
            size_kb="$(fs_path_size_kb "$item")"
            if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
                total_kb=$((total_kb + size_kb))
            fi
        done
        log info "[COB] Cleaning ${#to_remove[@]} backup item(s) (~$(human_size_kb "$total_kb") freed)"
    fi

    local spinner_active=false
    if [[ "$stats" != true && "${#to_remove[@]}" -gt 0 ]]; then
        spinner_start "Cleaning backups..."
        spinner_active=true
    fi

    local empty_dir=""
    for item in "${to_remove[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ "$fast" == true && -d "$item" ]] && command -v rsync >/dev/null 2>&1; then
            empty_dir="$(mktemp -d 2>/dev/null || mktemp -d -t inm-empty)"
            if [[ -n "$empty_dir" && -d "$empty_dir" ]]; then
                if ! fs_sync_dir "fast delete" "$empty_dir" "${item%/}" false quiet "COB" --delete >/dev/null 2>&1; then
                    log warn "[COB] Fast delete (rsync) failed for $item; falling back."
                fi
                safe_rm_rf "$empty_dir" "$(dirname "$empty_dir")" || true
            fi
        fi
        safe_rm_rf "$item" "$backup_path" || {
            log err "[COB] Failed to clean up old backup items."
            exit 1
        }
    done
    if [[ "$spinner_active" == true ]]; then
        spinner_stop
    fi
    log debug "[COB] Cleaning up done."
}

# ---------------------------------------------------------------------
# cleanup()
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# cleanup()
# Run cleanup for versions and backups.
# Consumes: env: DRY_RUN.
# Computes: cleanup tasks.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
cleanup() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cleanup."
        return 0
    fi
    local explicit=false
    local do_versions=false
    local do_backups=false
    local do_cache=false
    if [[ "${NAMED_ARGS[versions]:-}" != "" || "${NAMED_ARGS[version]:-}" != "" || "${NAMED_ARGS[backups]:-}" != "" || "${NAMED_ARGS[cache]:-}" != "" ]]; then
        explicit=true
        if args_is_true "${NAMED_ARGS[versions]:-}"; then
            do_versions=true
        elif [[ -n "${NAMED_ARGS[version]:-}" ]]; then
            case "${NAMED_ARGS[version],,}" in
                0|false|no|off) ;;
                *) do_versions=true ;;
            esac
        fi
        args_is_true "${NAMED_ARGS[backups]:-}" && do_backups=true
        args_is_true "${NAMED_ARGS[cache]:-}" && do_cache=true
    fi

    if [[ "$explicit" == true ]]; then
        if [[ "$do_versions" != true && "$do_backups" != true && "$do_cache" != true ]]; then
            log err "[CLEAN] No prune targets selected. Use --version and/or --backups."
            return 1
        fi
        log debug "[CLEAN] Pruning selected targets: versions=$do_versions backups=$do_backups cache=$do_cache"
        [[ "$do_versions" == true ]] && cleanup_old_versions
        [[ "$do_backups" == true ]] && cleanup_old_backups
        [[ "$do_cache" == true ]] && cleanup_cache
        return 0
    fi

    local keep="${INM_KEEP_BACKUPS:-2}"
    local cache_keep="${INM_CACHE_GLOBAL_RETENTION:-3}"
    log debug "[CLEAN] Removing old versions/backups/cache (keep backups/rollbacks: ${keep}, cache: ${cache_keep})"
    cleanup_old_versions
    cleanup_old_backups
    cleanup_cache
}
