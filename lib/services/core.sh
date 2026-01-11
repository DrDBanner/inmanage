#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_CORE_LOADED:-} ]] && return
__SERVICE_CORE_LOADED=1

# ---------------------------------------------------------------------
# get_installed_version()
# Read the installed Invoice Ninja version from VERSION.txt.
# Consumes: env: INM_INSTALLATION_PATH.
# Computes: installed version string.
# Returns: prints version; 1 if missing, 2 on read failure.
# ---------------------------------------------------------------------
get_installed_version() {
    log debug "[GIV] Retrieving installed version from VERSION.txt"
    local version_file="${INM_INSTALLATION_PATH%/}/VERSION.txt"

    if [ -f "$version_file" ]; then
        local version
        version=$(<"$version_file") || {
            log err "[GIV] Failed to read installed version from $version_file"
            return 2
        }
        log debug "[GIV] Installed version: $version"
        echo "$version"
        return 0
    else
        log info "[GIV] No VERSION.txt found – assuming fresh install"
        return 1
    fi
}

# ---------------------------------------------------------------------
# get_latest_version()
# Resolve the latest Invoice Ninja release version from GitHub.
# Consumes: deps: gh_release_latest_version/http_head_line; network access.
# Computes: latest version string.
# Returns: prints version; non-zero on failure.
# ---------------------------------------------------------------------
get_latest_version() {
    log debug "[GLV] Retrieving latest version from GitHub API"

    local version
    version="$(gh_release_latest_version "invoiceninja/invoiceninja" "v")" || {
        log err "[GLV] Failed to fetch latest version."
        return 1
    }

    if [[ -z "$version" || "$version" == "null" ]]; then
        local head_resp
        head_resp="$(http_head_line "https://api.github.com/repos/invoiceninja/invoiceninja/releases/latest")"
        log err "[GLV] Could not determine latest version. API response empty."
        log err "[GLV] GitHub reachable? HEAD returned: ${head_resp:-<no response>}"
        return 1
    fi

    log debug "[GLV] Latest version: $version"
    echo "$version"
}

# ---------------------------------------------------------------------
# fetch_release_digest()
# Fetch the SHA256 digest for a release asset.
# Consumes: args: version, asset_name; deps: gh_release_fetch_digest.
# Computes: digest string.
# Returns: prints digest or empty string.
# ---------------------------------------------------------------------
fetch_release_digest() {
    local version="$1"
    local asset_name="$2"
    gh_release_fetch_digest "invoiceninja/invoiceninja" "v${version}" "$asset_name" "invoiceninja.tar"
}

# ---------------------------------------------------------------------
# compute_sha256()
# Compute the SHA256 checksum of a file.
# Consumes: args: file; deps: compat_compute_sha256.
# Computes: checksum string.
# Returns: prints checksum or non-zero on failure.
# ---------------------------------------------------------------------
compute_sha256() {
    local file="$1"
    compat_compute_sha256 "$file"
}

# ---------------------------------------------------------------------
# apply_cache_file_mode()
# Apply cache file mode to given paths.
# Consumes: args: paths...; deps: cache_file_mode.
# Computes: chmod call for cache files.
# Returns: 0 (best effort).
# ---------------------------------------------------------------------
apply_cache_file_mode() {
    local mode
    mode="$(cache_file_mode)"
    chmod "$mode" "$@" 2>/dev/null || true
}

# ---------------------------------------------------------------------
# download_ninja()
# Download an Invoice Ninja release tarball (cached).
# Consumes: args: version (optional); deps: gh_release_download.
# Computes: cached release path.
# Returns: prints cache directory or non-zero on failure.
# ---------------------------------------------------------------------
download_ninja() {
    local version="$1"
    gh_release_download "invoiceninja/invoiceninja" "$version" "invoiceninja.tar.gz" "invoiceninja" "v" "invoiceninja.tar" "DN" 1048576
}

# ---------------------------------------------------------------------
# get_app_release()
# Cache a specific Invoice Ninja release without installing.
# Consumes: args: version(optional); deps: get_latest_version/download_ninja.
# Computes: cached release tarball in cache directory.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
get_app_release() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Would download app release to cache."
        return 0
    fi
    local -A args=()
    parse_named_args args "$@"

    local version
    version="$(args_get args "" version)"
    if [[ -z "$version" ]]; then
        version="$(get_latest_version)" || return 1
    fi

    log info "[GET] Fetching Invoice Ninja ${version}"
    local cache_dir
    cache_dir="$(download_ninja "$version")" || {
        log err "[GET] Download failed."
        return 1
    }
    log ok "[GET] Cached Invoice Ninja ${version} at $cache_dir"
    return 0
}

# ---------------------------------------------------------------------
# cleanup_cache()
# Remove old cached Invoice Ninja versions.
# Consumes: env: INM_CACHE_GLOBAL_RETENTION; deps: resolve_cache_directory.
# Computes: cache cleanup actions.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
cleanup_cache() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cache cleanup."
        return 0
    fi
    log debug "[CC] Cleaning up old cached Invoice Ninja versions..."

    local cache_dir
    cache_dir=$(resolve_cache_directory)

    if [ ! -d "$cache_dir" ]; then
        log warn "[CC] Cache directory $cache_dir does not exist. Skipping cleanup."
    fi

    find "$cache_dir" -maxdepth 1 -type f -name 'invoiceninja_*.tar.gz' \
        | sort -rV \
        | tail -n +$((INM_CACHE_GLOBAL_RETENTION + 1)) \
        | while read -r file; do
            log debug "[CC] Removing: $file"
            rm -f "$file"
        done

    log debug "[CC] Cleanup of cached versions completed."
}

# ---------------------------------------------------------------------
# artisan helpers
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# resolve_php_exec()
# Resolve a usable PHP CLI binary.
# Consumes: env: INM_PHP_EXECUTABLE; system PATH and /usr/iports.
# Computes: PHP executable path.
# Returns: prints php path to stdout.
# ---------------------------------------------------------------------
resolve_php_exec() {
    local php_exec="${INM_PHP_EXECUTABLE:-}"
    if [[ -n "$php_exec" && -x "$php_exec" ]]; then
        printf "%s" "$php_exec"
        return 0
    fi
    php_exec="$(command -v php 2>/dev/null || true)"
    if [[ -z "$php_exec" && -d /usr/iports ]]; then
        local candidates=()
        local php_dir=""
        for php_dir in /usr/iports/php*/bin/php; do
            [[ -x "$php_dir" ]] || continue
            local php_base
            php_base="$(basename "$(dirname "$php_dir")")"
            local php_num="${php_base#php}"
            if [[ "$php_num" =~ ^[0-9]+$ ]]; then
                candidates+=("${php_num}|${php_dir}")
            fi
        done
        if [ "${#candidates[@]}" -gt 0 ]; then
            local sorted_candidates=()
            mapfile -t sorted_candidates < <(printf '%s\n' "${candidates[@]}" | sort -rn)
            php_exec="${sorted_candidates[0]#*|}"
        fi
    fi
    printf "%s" "${php_exec:-php}"
}

# ---------------------------------------------------------------------
# artisan_cmd_string()
# Build the artisan command string for a given app dir.
# Consumes: args: app_dir; deps: resolve_php_exec.
# Computes: "php /path/to/artisan".
# Returns: prints command string.
# ---------------------------------------------------------------------
artisan_cmd_string() {
    local app_dir="${1:-${INM_INSTALLATION_PATH%/}}"
    printf "%s %s" "$(resolve_php_exec)" "${app_dir%/}/artisan"
}

# ---------------------------------------------------------------------
# run_artisan_in()
# Run artisan in a specific app directory.
# Consumes: args: app_dir, artisan args...; deps: resolve_php_exec.
# Computes: command execution with working directory.
# Returns: artisan exit code.
# ---------------------------------------------------------------------
run_artisan_in() {
    local app_dir="${1%/}"
    shift
    local artisan_bin="${app_dir}/artisan"

    if [ ! -f "$artisan_bin" ]; then
        log err "[ART] artisan not found at $artisan_bin"
        return 1
    fi

    (
        cd "$app_dir" || {
            log err "[ART] Cannot change to app dir: $app_dir"
            exit 1
        }
        "$(resolve_php_exec)" "$artisan_bin" "$@"
    )
}

# ---------------------------------------------------------------------
# run_artisan()
# Run artisan using INM_INSTALLATION_PATH.
# Consumes: args: artisan args...; env: INM_INSTALLATION_PATH; deps: run_artisan_in.
# Computes: command execution.
# Returns: artisan exit code.
# ---------------------------------------------------------------------
run_artisan() {
    run_artisan_in "${INM_INSTALLATION_PATH%/}" "$@"
}

# ---------------------------------------------------------------------
# show_versions_summary()
# Display installed, cached, and upstream versions.
# Consumes: env: INM_CACHE_GLOBAL_DIRECTORY, INM_CACHE_LOCAL_DIRECTORY.
# Computes: version summary.
# Returns: 0 after logging.
# ---------------------------------------------------------------------
show_versions_summary() {
    local installed latest cache_dir cached_versions=()

    installed="$(get_installed_version || true)"
    latest="$(get_latest_version || true)"

    # Read-only cache listing (avoid sudo on info/version)
    for candidate in "${INM_CACHE_GLOBAL_DIRECTORY:-$HOME/.cache/inmanage}" "${INM_CACHE_LOCAL_DIRECTORY:-$PWD/.cache}"; do
        if [ -d "$candidate" ] && [ -r "$candidate" ]; then
            cache_dir="$candidate"
            shopt -s nullglob
            for f in "$cache_dir"/invoiceninja_v*.tar.gz; do
                local base
                base="$(basename "$f")"
                base="${base#invoiceninja_v}"
                base="${base%.tar.gz}"
                cached_versions+=("$base")
            done
            shopt -u nullglob
            break
        fi
    done

    log info "[VER] Installed: ${installed:-<none>}"
    log info "[VER] Latest upstream: ${latest:-<unknown>}"
    if [ ${#cached_versions[@]} -gt 0 ]; then
        mapfile -t cached_versions < <(printf '%s\n' "${cached_versions[@]}" | sort -Vr)
        log info "[VER] Cached (${cache_dir}): ${cached_versions[*]}"
    else
        log info "[VER] Cached: <none>"
    fi
}

# ---------------------------------------------------------------------
# clear_application_cache()
# Clear application caches via artisan optimize:clear.
# Consumes: env: DRY_RUN; deps: run_artisan.
# Computes: cache clear command.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
clear_application_cache() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log info "[DRY-RUN] Skipping cache clear."
        return 0
    fi
    log info "[CACHE] Clearing application cache via artisan optimize:clear"
    if ! run_artisan optimize:clear; then
        log err "[CACHE] Failed to clear cache."
        return 1
    fi
    log ok "[CACHE] Cache cleared."
}
