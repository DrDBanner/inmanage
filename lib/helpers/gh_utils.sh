#!/usr/bin/env bash
# GitHub utility helpers (API auth + rate-limit checks).

# ---------------------------------------------------------------------
# check_gh_credentials()
# Populate CURL_AUTH_FLAG for curl helpers.
# Consumes: env: INM_GH_API_CREDENTIALS.
# Computes: CURL_AUTH_FLAG array/string.
# Returns: 0 always; logs debug about auth state.
# ---------------------------------------------------------------------
check_gh_credentials() {
    # Only set CURL_AUTH_FLAG for commands that actually download; keep quiet otherwise.
    local -a auth_args=()
    local auth_kind="none"
    gh_auth_args auth_args auth_kind
    if [ "${#auth_args[@]}" -gt 0 ]; then
        # shellcheck disable=SC2034
        CURL_AUTH_FLAG=("${auth_args[@]}")
        log debug "[GH] Credentials detected (${auth_kind}). Curl commands will include them."
    else
        # shellcheck disable=SC2034
        CURL_AUTH_FLAG=()
        log debug "[GH] No credentials set. If curl connections fail, try to add credentials."
    fi
}

# ---------------------------------------------------------------------
# check_github_rate_limit()
# Warn when GitHub API rate limit is low.
# Consumes: env: INM_GH_API_CREDENTIALS; tools: curl, jq, date.
# Computes: remaining/limit from API.
# Returns: 0 on fetch/parse, 1 on fetch failure.
# ---------------------------------------------------------------------
check_github_rate_limit() {
    local auth_flag=()
    gh_auth_args auth_flag
    local rl=""
    http_fetch_with_args "https://api.github.com/rate_limit" rl false --fail "${auth_flag[@]}" || return
    if ! command -v jq >/dev/null 2>&1; then
        return
    fi
    local remaining limit reset
    remaining=$(echo "$rl" | jq -r '.rate.remaining // empty')
    limit=$(echo "$rl" | jq -r '.rate.limit // empty')
    reset=$(echo "$rl" | jq -r '.rate.reset // empty')
    if [[ -n "$remaining" && -n "$limit" ]]; then
        if (( remaining <= 5 )); then
            local reset_human=""
            if [[ -n "$reset" ]] && command -v date >/dev/null 2>&1; then
                reset_human=$(date -d @"$reset" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
            fi
            log warn "[DN] GitHub API rate low: ${remaining}/${limit} remaining${reset_human:+ (reset: $reset_human)}. Set INM_GH_API_CREDENTIALS=token:<PAT> to increase limits."
        else
            log debug "[DN] GitHub API rate: ${remaining}/${limit} remaining."
        fi
    fi
}

# ---------------------------------------------------------------------
# gh_auth_args()
# Build curl auth args from INM_GH_API_CREDENTIALS.
# Consumes: env: INM_GH_API_CREDENTIALS.
# Computes: out_arr and optional kind (token|basic|none).
# Returns: 0 always.
# ---------------------------------------------------------------------
gh_auth_args() {
    # shellcheck disable=SC2034
    local -n out_arr="$1"
    local kind_var="${2:-}"
    # shellcheck disable=SC2034
    out_arr=()
    local kind="none"
    if trace_suspend_if_sensitive_key "INM_GH_API_CREDENTIALS"; then
        trap 'trace_resume' RETURN
    fi
    case "${INM_GH_API_CREDENTIALS:-}" in
        token:*)
            # shellcheck disable=SC2034
            out_arr=(-H "Authorization: token ${INM_GH_API_CREDENTIALS#token:}")
            kind="token"
            ;;
        *:*)
            # shellcheck disable=SC2034
            out_arr=(-u "${INM_GH_API_CREDENTIALS}")
            kind="basic"
            ;;
    esac
    if [[ -n "$kind_var" ]]; then
        printf -v "$kind_var" "%s" "$kind"
    fi
}

# ---------------------------------------------------------------------
# gh_release_latest_tag()
# Fetch latest release tag for a repo.
# Consumes: args: repo; deps: gh_auth_args/http_fetch_with_args; tools: jq.
# Computes: tag_name from GitHub API.
# Returns: tag on stdout; 1 if unavailable.
# ---------------------------------------------------------------------
gh_release_latest_tag() {
    local repo="$1"
    local response tag
    local -a auth_args=()
    gh_auth_args auth_args
    http_fetch_with_args "https://api.github.com/repos/${repo}/releases/latest" response false -L "${auth_args[@]}" || return 1
    tag="$(printf "%s" "$response" | jq -r '.tag_name' 2>/dev/null)"
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        return 1
    fi
    printf "%s" "$tag"
}

# ---------------------------------------------------------------------
# gh_release_latest_version()
# Fetch latest release version with optional prefix strip.
# Consumes: args: repo, prefix; deps: gh_release_latest_tag.
# Computes: tag normalization.
# Returns: version on stdout; 1 if unavailable.
# ---------------------------------------------------------------------
gh_release_latest_version() {
    local repo="$1"
    local prefix="${2:-}"
    local tag
    tag="$(gh_release_latest_tag "$repo")" || return 1
    if [[ -n "$prefix" ]]; then
        tag="${tag#"${prefix}"}"
    fi
    printf "%s" "$tag"
}

# ---------------------------------------------------------------------
# build_changelog_url()
# Build a GitHub compare URL for two versions.
# Consumes: args: from_version, to_version.
# Computes: compare URL.
# Returns: URL on stdout, empty on failure.
# ---------------------------------------------------------------------
build_changelog_url() {
    local from_version="$1"
    local to_version="$2"
    if [[ -z "$from_version" || -z "$to_version" ]]; then
        return 1
    fi
    local from_tag="${from_version#v}"
    local to_tag="${to_version#v}"
    if [[ -z "$from_tag" || -z "$to_tag" || "$from_tag" == "$to_tag" ]]; then
        return 1
    fi
    printf "https://github.com/invoiceninja/invoiceninja/compare/v%s...v%s" "$from_tag" "$to_tag"
}

# ---------------------------------------------------------------------
# emit_changelog_link()
# Emit a compare URL for a version range when requested.
# Consumes: args: label, from_version, to_version, show_flag.
# Computes: log output.
# Returns: 0 always.
# ---------------------------------------------------------------------
emit_changelog_link() {
    local label="$1"
    local from_version="$2"
    local to_version="$3"
    local show_flag="${4:-false}"

    if ! args_is_true "$show_flag"; then
        return 0
    fi
    local changelog_url=""
    changelog_url="$(build_changelog_url "$from_version" "$to_version" 2>/dev/null || true)"
    if [[ -n "$changelog_url" ]]; then
        log info "[${label}] Changelog: $changelog_url"
    else
        log info "[${label}] Changelog unavailable (need installed + target versions)."
    fi
}

# ---------------------------------------------------------------------
# gh_release_list_versions()
# List release versions (prefix stripped) for a repo.
# Consumes: args: repo, prefix, per_page; deps: gh_auth_args/http_fetch_with_args; tools: jq.
# Computes: list of versions.
# Returns: versions on stdout; 1 if jq/fetch fails.
# ---------------------------------------------------------------------
gh_release_list_versions() {
    local repo="$1"
    local prefix="${2:-}"
    local per_page="${3:-100}"
    local releases_json tags
    if ! command -v jq >/dev/null 2>&1; then
        return 1
    fi
    local -a auth_args=()
    gh_auth_args auth_args
    http_fetch_with_args "https://api.github.com/repos/${repo}/releases?per_page=${per_page}" \
        releases_json false -L "${auth_args[@]}" || return 1
    tags="$(printf "%s" "$releases_json" | jq -r '.[].tag_name' 2>/dev/null)"
    if [[ -n "$prefix" ]]; then
        tags="$(printf "%s\n" "$tags" | sed "s/^${prefix}//")"
    fi
    printf "%s\n" "$tags"
}

# ---------------------------------------------------------------------
# gh_release_fetch_digest()
# Fetch sha256 digest for an asset in a GitHub release.
# Consumes: args: repo, tag, asset_name, fallback_asset; deps: gh_auth_args/http_fetch_with_args; tools: jq.
# Computes: digest string (sha256: prefix stripped).
# Returns: digest on stdout (empty if not found).
# ---------------------------------------------------------------------
gh_release_fetch_digest() {
    local repo="$1"
    local tag="$2"
    local asset_name="$3"
    local fallback_asset="${4:-}"
    local api_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
    local digest response
    local -a auth_args=()
    gh_auth_args auth_args
    http_fetch_with_args "$api_url" response false "${auth_args[@]}" || true
    digest=$(printf "%s" "$response" | jq -r --arg name "$asset_name" '.assets[]? | select(.name==$name) | .digest // empty' 2>/dev/null | head -n1)
    if [[ -z "$digest" && -n "$fallback_asset" && "$fallback_asset" != "$asset_name" ]]; then
        digest=$(printf "%s" "$response" | jq -r --arg name "$fallback_asset" '.assets[]? | select(.name==$name) | .digest // empty' 2>/dev/null | head -n1)
        asset_name="$fallback_asset"
    fi
    if [[ "$digest" == sha256:* ]]; then
        digest="${digest#sha256:}"
    fi
    if [ -n "$digest" ]; then
        log debug "[GH] Release digest found for ${asset_name}: ${digest}"
        printf "%s" "$digest"
    fi
}

# ---------------------------------------------------------------------
# gh_release_download()
# Download a GitHub release asset with cache/resume/digest checks.
# Consumes: args: repo, version(optional), asset_name, cache_prefix, tag_prefix, digest_asset, label, min_bytes; env: INM_GH_API_CREDENTIALS.
# Computes: download to cache + checksum verification.
# Returns: cache dir path on stdout; exits on fatal errors.
# ---------------------------------------------------------------------
gh_release_download() {
    local repo="$1"
    local version="$2"
    local asset_name="$3"
    local cache_prefix="$4"
    local tag_prefix="${5:-v}"
    local digest_asset="${6:-$asset_name}"
    local label="${7:-DN}"
    local min_bytes="${8:-1048576}"

    if [[ -z "$repo" || -z "$asset_name" || -z "$cache_prefix" ]]; then
        log err "[${label}] Missing required args: repo/asset/cache_prefix"
        return 1
    fi

    if [[ -z "$version" ]]; then
        version="$(gh_release_latest_version "$repo" "$tag_prefix")" || {
            log err "[${label}] Failed to resolve latest version for ${repo}."
            return 1
        }
    fi

    local tag="${tag_prefix}${version}"
    local cache_dir target_file temp_file
    local cache_readonly=false
    local asset_suffix=""
    if [[ "$asset_name" == *.* ]]; then
        asset_suffix=".${asset_name#*.}"
    fi
    local global_cache=""
    local local_cache=""
    global_cache="$(expand_path_vars "${INM_CACHE_GLOBAL_DIRECTORY:-$HOME/.cache/inmanage}")"
    local_cache="$(expand_path_vars "${INM_CACHE_LOCAL_DIRECTORY:-./.cache}")"
    local cached_from=""
    local cached_fallback_dir=""
    local cached_fallback_file=""
    local candidate=""
    local candidate_dir=""
    for candidate_dir in "$global_cache" "$local_cache"; do
        [[ -z "$candidate_dir" ]] && continue
        candidate="${candidate_dir%/}/${cache_prefix}_v${version}${asset_suffix}"
        if [[ -f "$candidate" ]]; then
            if [[ -w "$candidate_dir" ]]; then
                cache_dir="$candidate_dir"
                target_file="$candidate"
                cached_from="$candidate_dir"
                cache_readonly=false
                break
            fi
            if [[ -z "$cached_fallback_dir" ]]; then
                cached_fallback_dir="$candidate_dir"
                cached_fallback_file="$candidate"
            fi
        fi
    done
    if [[ -z "$cache_dir" && -n "$cached_fallback_dir" ]]; then
        cache_dir="$cached_fallback_dir"
        target_file="$cached_fallback_file"
        cached_from="$cached_fallback_dir"
        cache_readonly=true
    fi
    if [[ -z "$cache_dir" ]]; then
        cache_dir=$(resolve_cache_directory)
        target_file="$cache_dir/${cache_prefix}_v${version}${asset_suffix}"
        cache_readonly=false
    fi
    temp_file="${target_file}.part"
    log debug "[${label}] Cache directory: $cache_dir"
    if [[ -n "$cached_from" && "$cached_from" != "$cache_dir" ]]; then
        log debug "[${label}] Cached file found in: $cached_from"
    fi
    if [[ "$cache_readonly" == true ]]; then
        local writable_cache
        writable_cache="$(resolve_cache_directory)"
        if [[ -n "$writable_cache" && "$writable_cache" != "$cache_dir" ]]; then
            local writable_target="${writable_cache%/}/${cache_prefix}_v${version}${asset_suffix}"
            if mkdir -p "$writable_cache" 2>/dev/null && cp -f "$target_file" "$writable_target" 2>/dev/null; then
                if [[ -f "${target_file}.sha256" ]]; then
                    cp -f "${target_file}.sha256" "${writable_target}.sha256" 2>/dev/null || true
                fi
                cache_dir="$writable_cache"
                target_file="$writable_target"
                temp_file="${target_file}.part"
                cache_readonly=false
                log debug "[${label}] Copied cached file to writable cache: $cache_dir"
            else
                log warn "[${label}] Cached file is in a read-only cache; using it as-is."
            fi
        fi
    fi

    if [[ "$cache_readonly" != true ]]; then
        # ensure cache dir exists and writable (prefer restricted perms; no sudo)
        if ! mkdir -p "$cache_dir" 2>/dev/null; then
            log err "[${label}] Cannot create cache directory: $cache_dir"
            exit 1
        fi
        apply_cache_dir_mode "$cache_dir"
        if [ ! -w "$cache_dir" ]; then
            # fallback to local cache within PWD if global not writable
            local fallback="${PWD}/.cache/inmanage"
            log warn "[${label}] Cache directory not writable: $cache_dir. Falling back to local cache: $fallback"
            if ! mkdir -p "$fallback" 2>/dev/null; then
                log err "[${label}] Cannot create local fallback cache: $fallback"
                exit 1
            fi
            apply_cache_dir_mode "$fallback"
            if [ ! -w "$fallback" ]; then
                log err "[${label}] Neither global nor local cache is writable."
                exit 1
            fi
            cache_dir="$fallback"
            target_file="$cache_dir/${cache_prefix}_v${version}${asset_suffix}"
            temp_file="${target_file}.part"
        fi
    fi

    local checksum_file="${target_file}.sha256"
    local expected_digest=""
    if [[ "${NAMED_ARGS[bypass_check_sha]:-false}" != true ]]; then
        log debug "[${label}] Retrieving release digest for ${tag}..."
        expected_digest="$(gh_release_fetch_digest "$repo" "$tag" "$digest_asset")"
        if [ -n "$expected_digest" ]; then
            if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
                log ok "[${label}] Release digest retrieved."
            else
                log debug "[${label}] Release digest retrieved."
            fi
        else
            log warn "[${label}] Release digest missing for ${tag}."
        fi
    else
        log warn "[${label}] SHA check bypassed via --bypass-check-sha."
    fi
    if declare -f check_github_rate_limit >/dev/null; then
        check_github_rate_limit
    fi

    if [[ "$cache_readonly" != true ]]; then
        # Quick write test to cache dir
        if ! touch "$cache_dir/.inm_cache_test" 2>/dev/null; then
            log err "[${label}] Cache directory not writable (touch failed): $cache_dir"
            exit 1
        fi
        rm -f "$cache_dir/.inm_cache_test" >/dev/null 2>&1
    fi

    if [ -f "$target_file" ]; then
        log debug "[${label}] Using cached version for $version at $target_file"
        if [ -f "$checksum_file" ]; then
            local stored sum
            stored="$(cut -d' ' -f1 "$checksum_file" 2>/dev/null)"
            sum="$(compute_sha256 "$target_file")"
            local reference=""
            if [ -n "$expected_digest" ]; then
                reference="$expected_digest"
            elif [ -n "$stored" ]; then
                reference="$stored"
                log warn "[${label}] Release digest missing for ${tag}; using cached checksum file."
            fi
            if [[ -n "$reference" && "$reference" != "$sum" ]]; then
                if [[ "${NAMED_ARGS[bypass_check_sha]:-false}" == true ]]; then
                    log warn "[${label}] Cached checksum mismatch but bypass enabled; using cached file."
                    dirname "$target_file"
                    return 0
                fi
                if [[ "$cache_readonly" == true ]]; then
                    log err "[${label}] Cached checksum mismatch in read-only cache; cannot replace."
                    return 1
                fi
                log warn "[${label}] Cached file checksum mismatch; re-downloading."
                rm -f "$target_file" "$checksum_file"
            else
                log debug "[${label}] Cached checksum verified."
                dirname "$target_file"
                return 0
            fi
        else
            log debug "[${label}] No checksum file; verifying cache now."
            local sum
            sum="$(compute_sha256 "$target_file")"
            if [[ -z "$expected_digest" && "${NAMED_ARGS[bypass_check_sha]:-false}" != true ]]; then
                log err "[${label}] Release digest missing for ${tag}; refusing to use cache without checksum."
                log_hint "$label" "Override with --bypass-check-sha if you accept the risk."
                return 1
            fi
            if [[ -n "$expected_digest" && "$expected_digest" != "$sum" ]]; then
                if [[ "${NAMED_ARGS[bypass_check_sha]:-false}" == true ]]; then
                    log warn "[${label}] Cached file does not match release digest but bypass enabled; using cached file."
                    if [[ "$cache_readonly" != true ]]; then
                        echo "$sum  $target_file" > "$checksum_file"
                        apply_cache_file_mode "$checksum_file"
                    fi
                    dirname "$target_file"
                    return 0
                fi
                if [[ "$cache_readonly" == true ]]; then
                    log err "[${label}] Cached digest mismatch in read-only cache; cannot replace."
                    return 1
                fi
                log warn "[${label}] Cached file does not match release digest; re-downloading."
                rm -f "$target_file"
            else
                if [[ "$cache_readonly" != true ]]; then
                    echo "$sum  $target_file" > "$checksum_file"
                    apply_cache_file_mode "$checksum_file"
                fi
                dirname "$target_file"
                return 0
            fi
        fi
    fi

    if [[ -z "$expected_digest" && "${NAMED_ARGS[bypass_check_sha]:-false}" != true ]]; then
        log err "[${label}] Release digest missing for ${tag}; refusing to download."
        log_hint "$label" "Override with --bypass-check-sha if you accept the risk."
        return 1
    fi

    log debug "[${label}] Fetching release archive for ${tag}..."

    local -a auth_args=()
    local auth_kind="none"
    gh_auth_args auth_args auth_kind
    if [[ "$auth_kind" == "token" ]]; then
        log debug "[${label}] Using GitHub token for download."
    elif [[ "$auth_kind" == "basic" ]]; then
        log debug "[${label}] Using GitHub user/password for download."
    else
        log debug "[${label}] No GitHub credentials provided; continuing unauthenticated."
    fi

    local download_url="https://github.com/${repo}/releases/download/${tag}/${asset_name}"
    local curl_opts=(--fail --location --connect-timeout 20 --max-time 600 --show-error)
    local use_spinner=false
    if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
        curl_opts+=(--progress-bar)
    else
        curl_opts+=(--silent)
        use_spinner=true
    fi
    if [[ -n "${auth_args[*]}" ]]; then
        curl_opts+=("${auth_args[@]}")
    fi

    log debug "[${label}] Downloading from: $download_url"
    local resume_flag=()
    if [ -f "$temp_file" ]; then
        resume_flag=(--continue-at -)
        log debug "[${label}] Resuming download (partial file found)."
    fi
    local curl_rc=0
    if [ "$use_spinner" = true ]; then
        spinner_start "Fetching release archive..."
        http_curl "$label" "$download_url" "${curl_opts[@]}" "${resume_flag[@]}" -o "$temp_file"
        curl_rc=$?
        spinner_stop
    else
        http_curl "$label" "$download_url" "${curl_opts[@]}" "${resume_flag[@]}" -o "$temp_file"
        curl_rc=$?
    fi
    if [ "$curl_rc" -eq 0 ]; then
        if [ "$(wc -c < "$temp_file")" -gt "$min_bytes" ]; then
            if ! safe_move_or_copy_and_clean "$temp_file" "$target_file" move; then
                log err "[${label}] Failed to finalize download: $temp_file -> $target_file"
                rm -f "$temp_file"
                exit 1
            fi
            local sum_dl
            sum_dl="$(compute_sha256 "$target_file")"
            if [[ -n "$expected_digest" && "$expected_digest" != "$sum_dl" ]]; then
                if [[ "${NAMED_ARGS[bypass_check_sha]:-false}" == true ]]; then
                    log warn "[${label}] Downloaded file digest mismatch but bypass enabled; continuing."
                else
                    log err "[${label}] Downloaded file digest mismatch (expected $expected_digest, got $sum_dl)."
                    rm -f "$target_file" "$checksum_file"
                    exit 1
                fi
            fi
            echo "$sum_dl  $target_file" > "$checksum_file" 2>/dev/null || true
            apply_cache_file_mode "$target_file" "$checksum_file"
        else
            log err "[${label}] Download failed: File is too small. Please check network."
            rm -f "$temp_file"
            exit 1
        fi
    else
        if [ "$curl_rc" -eq 28 ]; then
            log err "[${label}] Download timed out (curl exit 28). Re-run to resume from partial."
            log_hint "$label" "If downloads are consistently slow, set INM_GH_API_CREDENTIALS (token:x-oauth) or use a mirror/proxy."
        else
            log err "[${label}] Download failed via curl (exit $curl_rc). Please check network. Maybe you need GitHub credentials or --ipv4/--proxy."
        fi
        if [ -f "$temp_file" ]; then
            log warn "[${label}] Partial file kept for resume: $temp_file"
        fi
        exit 1
    fi

    log debug "[${label}] ${repo} ${version} downloaded and cached at $target_file"
    dirname "$target_file"
}
