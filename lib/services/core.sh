#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_CORE_LOADED:-} ]] && return
__SERVICE_CORE_LOADED=1

# ---------------------------------------------------------------------
# get_installed_version()
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
# ---------------------------------------------------------------------
get_latest_version() {
    log debug "[GLV] Retrieving latest version from GitHub API"

    local version
    version=$(curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} "https://api.github.com/repos/invoiceninja/invoiceninja/releases/latest" | jq -r '.tag_name' | sed 's/^v//') || {
        log err "[GLV] Failed to fetch latest version."
        return 1
    }

    if [[ -z "$version" || "$version" == "null" ]]; then
        log err "[GLV] Could not determine latest version. API response empty."
        return 1
    fi

    log debug "[GLV] Latest version: $version"
    echo "$version"
}

# ---------------------------------------------------------------------
# download_ninja()
# ---------------------------------------------------------------------
download_ninja() {
    local version="$1"
    local cache_dir
    local target_file
    local temp_file

    temp_file=$(mktemp)
    cache_dir=$(resolve_cache_directory)
    target_file="$cache_dir/invoiceninja_v$version.tar.gz"
    local force="${NAMED_ARGS[force]:-false}"
    local debug_keep_tmp="${NAMED_ARGS[debug_keep_tmp]:-false}"

    if [ -f "$target_file" ]; then
        log debug "[DN] Using cached version for $version at $target_file"
        dirname "$target_file"
        return 0
    fi

    log info "[DN] Downloading Invoice Ninja $version..."

    if [ -n "$INM_GH_API_CREDENTIALS" ]; then
        log debug "[DN] Using GitHub API credentials for download."
        if [[ "$INM_GH_API_CREDENTIALS" =~ ^token: ]]; then
            CURL_AUTH_FLAG="-H 'Authorization: token ${INM_GH_API_CREDENTIALS#token:}'"
        elif [[ "$INM_GH_API_CREDENTIALS" =~ ^[^:]*: ]]; then
            USERNAME_PASSWORD="${INM_GH_API_CREDENTIALS//:/ }"
            CURL_AUTH_FLAG="-u ${USERNAME_PASSWORD}"
        else
            log warn "[DN] Invalid INM_GH_API_CREDENTIALS format, skipping authentication"
            CURL_AUTH_FLAG=""
        fi
    fi

    local download_url="https://github.com/invoiceninja/invoiceninja/releases/download/v$version/invoiceninja.tar.gz"

    if curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} -w "%{http_code}" "$download_url" -o "$temp_file" | grep -q "200"; then
        if [ "$(wc -c < "$temp_file")" -gt 1048576 ]; then
            safe_move_or_copy_and_clean "$temp_file" "$target_file" move
            log ok "[DN] Download successful."
        else
            log err "[DN] Download failed: File is too small. Please check network."
            rm "$temp_file"
            exit 1
        fi
    else
        log err "[DN] Download failed: HTTP-Statuscode not 200. Please check network. Maybe you need GitHub credentials."
        rm "$temp_file"
        exit 1
    fi

    log ok "[DN] Invoice Ninja $version downloaded and cached at $target_file"
    dirname "$target_file"
}

# ---------------------------------------------------------------------
# cleanup_cache()
# ---------------------------------------------------------------------
cleanup_cache() {
    log info "[CC] Cleaning up old cached Invoice Ninja versions..."

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

    log ok "[CC] Cleanup of cached versions completed. Keeping the last $INM_CACHE_GLOBAL_RETENTION versions."
}

# ---------------------------------------------------------------------
# artisan helpers
# ---------------------------------------------------------------------
artisan_cmd_string() {
    local app_dir="${1:-${INM_INSTALLATION_PATH%/}}"
    printf "%s %s" "${INM_PHP_EXECUTABLE:-php}" "${app_dir%/}/artisan"
}

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
        "${INM_PHP_EXECUTABLE:-php}" "$artisan_bin" "$@"
    )
}

run_artisan() {
    run_artisan_in "${INM_INSTALLATION_PATH%/}" "$@"
}

# ---------------------------------------------------------------------
# show_versions_summary()
# Displays installed, cached, and upstream versions.
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
        IFS=$'\n' cached_versions=($(printf '%s\n' "${cached_versions[@]}" | sort -Vr))
        log info "[VER] Cached (${cache_dir}): ${cached_versions[*]}"
    else
        log info "[VER] Cached: <none>"
    fi
}

# ---------------------------------------------------------------------
# do_snappdf()
# ---------------------------------------------------------------------
do_snappdf() {
    log info "[SNAP] Installing/Updating Snappdf (headless Chromium) …"

    local snappdf_dir="${INM_INSTALLATION_PATH%/}/vendor/beganovich/snappdf"
    local snappdf_bin="$snappdf_dir/versions/Chromium.app/Contents/MacOS/Chromium"

    if [ -x "$snappdf_bin" ]; then
        log debug "[SNAP] Snappdf already present."
        return 0
    fi

    (cd "$snappdf_dir" && run_artisan snappdf:install) || {
        log warn "[SNAP] Snappdf install failed."
        return 1
    }

    log ok "[SNAP] Snappdf install finished."
}

# ---------------------------------------------------------------------
# clear_application_cache()
# Wrapper to clear caches via artisan.
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
