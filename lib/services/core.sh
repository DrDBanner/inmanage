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
# fetch_release_digest()
# Fetches the sha256 digest for a given asset from the GitHub release API.
# Returns empty string if not found/available.
# ---------------------------------------------------------------------
fetch_release_digest() {
    local version="$1"
    local asset_name="$2"
    local api_url="https://api.github.com/repos/invoiceninja/invoiceninja/releases/tags/v${version}"
    local digest
    digest=$(curl -s "$api_url" | jq -r --arg name "$asset_name" '.assets[]? | select(.name==$name) | .digest // empty' 2>/dev/null | head -n1)
    # Try fallback asset name if nothing found
    if [[ -z "$digest" && "$asset_name" != "invoiceninja.tar" ]]; then
        digest=$(curl -s "$api_url" | jq -r '.assets[]? | select(.name=="invoiceninja.tar") | .digest // empty' 2>/dev/null | head -n1)
        asset_name="invoiceninja.tar"
    fi
    # Strip prefix if present (sha256:...)
    if [[ "$digest" == sha256:* ]]; then
        digest="${digest#sha256:}"
    fi
    if [ -n "$digest" ]; then
        log debug "[DN] Release digest found for $asset_name: $digest"
        echo "$digest"
    fi
}

# ---------------------------------------------------------------------
# compute_sha256()
# ---------------------------------------------------------------------
compute_sha256() {
    local file="$1"
    sha256sum "$file" | awk '{print $1}'
}

# ---------------------------------------------------------------------
# download_ninja()
# ---------------------------------------------------------------------
download_ninja() {
    local version="$1"
    local cache_dir
    local target_file
    local temp_file

    cache_dir=$(resolve_cache_directory)
    target_file="$cache_dir/invoiceninja_v$version.tar.gz"
    temp_file="${target_file}.part"
    log info "[DN] Cache directory: $cache_dir"
    # ensure cache dir exists and writable (prefer restricted perms; no sudo)
    if ! mkdir -p "$cache_dir" 2>/dev/null; then
        log err "[DN] Cannot create cache directory: $cache_dir"
        exit 1
    fi
    chmod u+rwX,g+rwX,o-rwx "$cache_dir" 2>/dev/null || log warn "[DN] Could not tighten cache permissions (trying to continue)"
    if [ ! -w "$cache_dir" ]; then
        # fallback to local cache within PWD if global not writable
        local fallback="${PWD}/.cache/inmanage"
        log warn "[DN] Cache directory not writable: $cache_dir. Falling back to local cache: $fallback"
        if ! mkdir -p "$fallback" 2>/dev/null; then
            log err "[DN] Cannot create local fallback cache: $fallback"
            exit 1
        fi
        chmod u+rwX,g+rwX,o-rwx "$fallback" 2>/dev/null || true
        if [ ! -w "$fallback" ]; then
            log err "[DN] Neither global nor local cache is writable."
            exit 1
        fi
        cache_dir="$fallback"
        target_file="$cache_dir/invoiceninja_v$version.tar.gz"
        temp_file="${target_file}.part"
    fi
    local force="${NAMED_ARGS[force]:-false}"
    local debug_keep_tmp="${NAMED_ARGS[debug_keep_tmp]:-false}"
    local checksum_file="${target_file}.sha256"
    local expected_digest=""
    if [[ "${NAMED_ARGS[bypass_check_sha]:-false}" != true ]]; then
        expected_digest="$(fetch_release_digest "$version" "$(basename "$target_file")")"
    else
        log warn "[DN] SHA check bypassed via --bypass-check-sha."
    fi
    if declare -f check_github_rate_limit >/dev/null; then
        check_github_rate_limit
    fi

    # Quick write test to cache dir
    if ! touch "$cache_dir/.inm_cache_test" 2>/dev/null; then
        log err "[DN] Cache directory not writable (touch failed): $cache_dir"
        exit 1
    fi
    rm -f "$cache_dir/.inm_cache_test" >/dev/null 2>&1

    if [ -f "$target_file" ]; then
        log debug "[DN] Using cached version for $version at $target_file"
        if [ -f "$checksum_file" ]; then
            local stored sum
            stored="$(cut -d' ' -f1 "$checksum_file" 2>/dev/null)"
            sum="$(compute_sha256 "$target_file")"
            # Prefer expected_digest if available
            local reference="${expected_digest:-$stored}"
            if [[ -n "$reference" && "$reference" != "$sum" ]]; then
                if [[ "${NAMED_ARGS[bypass_check_sha]:-false}" == true ]]; then
                    log warn "[DN] Cached checksum mismatch but bypass enabled; using cached file."
                    dirname "$target_file"
                    return 0
                fi
                log warn "[DN] Cached file checksum mismatch; re-downloading."
                rm -f "$target_file" "$checksum_file"
            else
                log debug "[DN] Cached checksum verified."
                dirname "$target_file"
                return 0
            fi
        else
            log debug "[DN] No checksum file; verifying cache now."
            local sum
            sum="$(compute_sha256 "$target_file")"
            if [[ -n "$expected_digest" && "$expected_digest" != "$sum" ]]; then
                if [[ "${NAMED_ARGS[bypass_check_sha]:-false}" == true ]]; then
                    log warn "[DN] Cached file does not match release digest but bypass enabled; using cached file."
                    echo "$sum  $target_file" > "$checksum_file"
                    dirname "$target_file"
                    return 0
                fi
                log warn "[DN] Cached file does not match release digest; re-downloading."
                rm -f "$target_file"
            else
                echo "$sum  $target_file" > "$checksum_file"
                dirname "$target_file"
                return 0
            fi
        fi
    fi

    log info "[DN] Downloading Invoice Ninja $version..."

    case "${INM_GH_API_CREDENTIALS:-}" in
        ""|"0"|"false"|"no"|"none")
            CURL_AUTH_FLAG=""
            log debug "[DN] No GitHub credentials provided; continuing unauthenticated."
            ;;
        token:*)
            log debug "[DN] Using GitHub token for download."
            CURL_AUTH_FLAG="-H 'Authorization: token ${INM_GH_API_CREDENTIALS#token:}'"
            ;;
        *:*)
            log debug "[DN] Using GitHub user/password for download."
            USERNAME_PASSWORD="${INM_GH_API_CREDENTIALS//:/ }"
            CURL_AUTH_FLAG="-u ${USERNAME_PASSWORD}"
            ;;
        *)
            log warn "[DN] Invalid INM_GH_API_CREDENTIALS format, skipping authentication"
            CURL_AUTH_FLAG=""
            ;;
    esac

    local download_url="https://github.com/invoiceninja/invoiceninja/releases/download/v$version/invoiceninja.tar.gz"
    # Show progress when interactive or in debug; otherwise stay quiet
    local curl_opts=(--fail --location --connect-timeout 20 --max-time 600 --show-error)
    if [ -t 1 ] || [[ "${DEBUG:-false}" == true ]]; then
        curl_opts+=(--progress-bar)
        log info "[DN] Download in progress..."
    else
        curl_opts+=(--silent)
        log info "[DN] Download in progress (quiet mode, use --debug to see progress)..."
    fi
    if [[ -n "$CURL_AUTH_FLAG" ]]; then
        # shellcheck disable=SC2206
        curl_opts+=($CURL_AUTH_FLAG)
    fi

    log info "[DN] Downloading from: $download_url"
    # Resume partial download if .part exists
    local resume_flag=()
    if [ -f "$temp_file" ]; then
        resume_flag=(--continue-at -)
        log info "[DN] Resuming download (partial file found)."
    fi
    if curl "${curl_opts[@]}" "${resume_flag[@]}" "$download_url" -o "$temp_file"; then
        if [ "$(wc -c < "$temp_file")" -gt 1048576 ]; then
            safe_move_or_copy_and_clean "$temp_file" "$target_file" move
            # Store checksum for future verification
            local sum_dl
            sum_dl="$(compute_sha256 "$target_file")"
            if [[ -n "$expected_digest" && "$expected_digest" != "$sum_dl" ]]; then
                if [[ "${NAMED_ARGS[bypass_check_sha]:-false}" == true ]]; then
                    log warn "[DN] Downloaded file digest mismatch but bypass enabled; continuing."
                else
                    log err "[DN] Downloaded file digest mismatch (expected $expected_digest, got $sum_dl)."
                    rm -f "$target_file" "$checksum_file"
                    exit 1
                fi
            fi
            echo "$sum_dl  $target_file" > "$checksum_file" 2>/dev/null || true
            log ok "[DN] Download successful."
        else
            log err "[DN] Download failed: File is too small. Please check network."
            rm -f "$temp_file"
            exit 1
        fi
    else
        local curl_rc=$?
        if [ "$curl_rc" -eq 28 ]; then
            log err "[DN] Download timed out (curl exit 28). Re-run to resume from partial."
        else
            log err "[DN] Download failed via curl (exit $curl_rc). Please check network. Maybe you need GitHub credentials or --ipv4/--proxy."
        fi
        if [ -f "$temp_file" ]; then
            log warn "[DN] Partial file kept for resume: $temp_file"
        fi
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
    local pdf_gen="${PDF_GENERATOR:-}"
    if [ -z "$pdf_gen" ] && [ -f "${INM_ENV_FILE:-}" ]; then
        pdf_gen=$(grep -E '^PDF_GENERATOR=' "$INM_ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)
    fi
    if [[ "${pdf_gen,,}" != "snappdf" ]]; then
        log info "[SNAP] PDF_GENERATOR is not 'snappdf'; skipping snappdf install."
        return 0
    fi

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
