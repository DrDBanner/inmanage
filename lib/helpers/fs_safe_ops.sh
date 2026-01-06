#!/usr/bin/env bash

# ---------------------------------------------------------------------
# safe_move_or_copy_and_clean()
# Move or copy a path, with rsync fallback and cleanup.
# Consumes: args: src, dst, mode; env: INM_SMO_LOG_LEVEL; tools: mv/cp/rsync.
# Computes: copy/move plus optional cleanup.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
safe_move_or_copy_and_clean() {
    local src="$1"
    local dst="$2"
    local mode="${3:-move}"      # move or copy
    local ok_level="${INM_SMO_LOG_LEVEL:-debug}"

    case "$ok_level" in
        ok|info|debug) ;;
        *) ok_level="ok" ;;
    esac

    if [ -z "$src" ] || [ -z "$dst" ]; then
        log err "[SMO] Source or destination missing."
        return 1
    fi
    if [ -f "$src" ]; then
        if [ -d "$dst" ] || [[ "$dst" == */ ]]; then
            log err "[SMO] Destination is a directory for file source: $dst"
            return 1
        fi
        if [ "$mode" = "move" ] || [ "$mode" = "new" ]; then
            if mv "$src" "$dst"; then
                log "$ok_level" "[SMO] Moved file $src to $dst"
                return 0
            fi
        else
            if cp -a "$src" "$dst"; then
                log "$ok_level" "[SMO] Copied file $src to $dst"
                return 0
            fi
        fi
        log err "[SMO] File move/copy failed: $src -> $dst"
        return 1
    fi
    if [ ! -d "$src" ]; then
        log err "[SMO] Source is not a directory: $src"
        return 1
    fi
    if [ -e "$dst" ] && [ ! -d "$dst" ]; then
        log err "[SMO] Destination exists but is not a directory: $dst"
        return 1
    fi

    if [ "$mode" = "move" ] || [ "$mode" = "new" ]; then
        if mv "$src" "$dst"; then
            log "$ok_level" "[SMO] Moved $src to $dst"
            return 0
        fi
        log warn "[SMO] mv failed, trying rsync copy..."
    fi

    if [ ! -d "$dst" ]; then
        mkdir -p "$dst" || {
            log err "[SMO] Failed to create destination directory: $dst"
            return 1
        }
    fi
    rsync -a --delete "$src/" "$dst/" || {
        log err "[SMO] rsync failed from $src to $dst"
        return 1
    }

    if [ "$mode" = "move" ] || [ "$mode" = "new" ]; then
        safe_rm_rf "$src" "$(dirname "$src")" || log warn "[SMO] Failed to remove source $src after copy"
    fi

    log "$ok_level" "[SMO] Copied $src to $dst"
    return 0
}

# ---------------------------------------------------------------------
# fs_with_smo_log_level()
# Run a command with a temporary SMO log level.
# Consumes: args: level, command; env: INM_SMO_LOG_LEVEL.
# Computes: executes command with scoped log level.
# Returns: command exit status.
# ---------------------------------------------------------------------
fs_with_smo_log_level() {
    local level="$1"
    shift || true
    local prev=""
    if [[ -n "$level" ]]; then
        prev="${INM_SMO_LOG_LEVEL:-}"
        INM_SMO_LOG_LEVEL="$level"
    fi
    "$@"
    local rc=$?
    if [[ -n "$level" ]]; then
        if [[ -n "$prev" ]]; then
            INM_SMO_LOG_LEVEL="$prev"
        else
            unset INM_SMO_LOG_LEVEL
        fi
    fi
    return "$rc"
}

# ---------------------------------------------------------------------
# fs_stage_dir()
# Stage a directory move/copy into a parent.
# Consumes: args: src, dst, parent, mode, smolog; deps: safe_move_or_copy_and_clean.
# Computes: ensures parent and moves/copies src to dst.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
fs_stage_dir() {
    local src="$1"
    local dst="$2"
    local parent="$3"
    local mode="${4:-move}"
    local smolog="${5:-}"
    if [[ -z "$src" || -z "$dst" || -z "$parent" ]]; then
        return 1
    fi
    mkdir -p "$parent" || return 1
    safe_rm_rf "$dst" "$parent" || true
    if [[ -n "$smolog" ]]; then
        fs_with_smo_log_level "$smolog" safe_move_or_copy_and_clean "$src" "$dst" "$mode"
    else
        safe_move_or_copy_and_clean "$src" "$dst" "$mode"
    fi
}

# ---------------------------------------------------------------------
# fs_cleanup_stage()
# Remove a staging directory unless simulate is true.
# Consumes: args: stage, simulate; deps: safe_rm_rf.
# Computes: cleanup of stage.
# Returns: 0 always.
# ---------------------------------------------------------------------
fs_cleanup_stage() {
    local stage="$1"
    local simulate="$2"
    if [[ "$simulate" != true && -n "$stage" && -d "$stage" ]]; then
        safe_rm_rf "$stage" "$(dirname "$stage")"
    fi
}

# ---------------------------------------------------------------------
# safe_rm_rf()
# Remove a path only if it is within allowed roots.
# Consumes: args: target, roots; tools: realpath/rm.
# Computes: safety checks then rm -rf.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
safe_rm_rf() {
    local target="$1"
    shift || true
    local roots=("$@")
    if [[ -z "$target" ]]; then
        log err "[FS] Refusing to remove empty path."
        return 1
    fi
    local resolved
    resolved="$(realpath "$target" 2>/dev/null || echo "$target")"
    if [[ "$resolved" != /* ]]; then
        local parent base parent_abs
        parent="$(dirname "$target")"
        base="$(basename "$target")"
        parent_abs="$(cd "$parent" 2>/dev/null && pwd)"
        if [[ -n "$parent_abs" ]]; then
            resolved="${parent_abs%/}/$base"
        fi
    fi
    if [[ -z "$resolved" || "$resolved" == "/" || "$resolved" == "." || "$resolved" == ".." ]]; then
        log err "[FS] Refusing to remove unsafe path: ${target}"
        return 1
    fi
    if [[ ${#roots[@]} -eq 0 ]]; then
        log err "[FS] Refusing to remove without allowed roots: $resolved"
        return 1
    fi
    local ok=false
    local root root_resolved root_prefix
    for root in "${roots[@]}"; do
        [[ -z "$root" ]] && continue
        root_resolved="$(realpath "$root" 2>/dev/null || echo "$root")"
        [[ -z "$root_resolved" ]] && continue
        root_prefix="$root_resolved"
        [[ "$root_prefix" != */ ]] && root_prefix="${root_prefix}/"
        if [[ "$resolved" == "$root_resolved" || "$resolved" == "$root_prefix"* ]]; then
            ok=true
            break
        fi
    done
    if [[ "$ok" != true ]]; then
        log err "[FS] Refusing to remove outside allowed roots: $resolved"
        return 1
    fi
    rm -rf -- "$target"
}

# ---------------------------------------------------------------------
# fs_sync_dir()
# Rsync a directory's contents with optional spinner.
# Consumes: args: label, src, dest, simulate, mode, prefix, rsync_args...; deps: rsync/spinner_run_optional/spinner_run_quiet.
# Computes: rsync copy (src/. -> dest/).
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
fs_sync_dir() {
    local label="$1"
    local src="$2"
    local dest="$3"
    local simulate="${4:-false}"
    local mode="${5:-normal}"
    local prefix="${6:-FS}"
    shift 6 || true
    local rsync_args=("$@")

    if [[ -z "$src" || -z "$dest" ]]; then
        return 1
    fi
    if [[ "$simulate" == true ]]; then
        log info "[DRY-RUN] Would copy ${label} -> ${dest}"
        return 0
    fi
    log info "[${prefix}] Copying ${label} via rsync -> ${dest}"
    mkdir -p "$dest"

    if declare -F spinner_run_optional >/dev/null 2>&1; then
        case "$mode" in
            quiet)
                spinner_run_quiet "Copying ${label}..." rsync -a "${rsync_args[@]}" "$src/." "$dest/"
                return $?
                ;;
            normal|"")
                spinner_run_optional "Copying ${label}..." rsync -a "${rsync_args[@]}" "$src/." "$dest/"
                return $?
                ;;
        esac
    fi

    rsync -a "${rsync_args[@]}" "$src/." "$dest/"
}

# ---------------------------------------------------------------------
# fs_sync_path()
# Rsync a file or directory into a destination directory.
# Consumes: args: label, src, dest, simulate, mode, prefix, rsync_args...; deps: rsync/spinner_run_optional/spinner_run_quiet.
# Computes: rsync copy (src -> dest/).
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
fs_sync_path() {
    local label="$1"
    local src="$2"
    local dest="$3"
    local simulate="${4:-false}"
    local mode="${5:-normal}"
    local prefix="${6:-FS}"
    shift 6 || true
    local rsync_args=("$@")

    if [[ -z "$src" || -z "$dest" ]]; then
        return 1
    fi
    if [[ "$simulate" == true ]]; then
        log info "[DRY-RUN] Would copy ${label} -> ${dest}"
        return 0
    fi
    if [[ -d "$src" ]]; then
        fs_sync_dir "$label" "$src" "$dest" "$simulate" "$mode" "$prefix" "${rsync_args[@]}"
        return $?
    fi
    if [[ ! -f "$src" ]]; then
        return 1
    fi

    log info "[${prefix}] Copying ${label} via rsync -> ${dest}"
    mkdir -p "$dest"
    if declare -F spinner_run_optional >/dev/null 2>&1; then
        case "$mode" in
            quiet)
                spinner_run_quiet "Copying ${label}..." rsync -a "${rsync_args[@]}" "$src" "$dest/"
                return $?
                ;;
            normal|"")
                spinner_run_optional "Copying ${label}..." rsync -a "${rsync_args[@]}" "$src" "$dest/"
                return $?
                ;;
        esac
    fi
    rsync -a "${rsync_args[@]}" "$src" "$dest/"
}
