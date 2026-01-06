#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HELPER_CLI_INFO_LOADED:-} ]] && return
__HELPER_CLI_INFO_LOADED=1

# ---------------------------------------------------------------------
# cli_resolve_root()
# Resolve the CLI root directory.
# Consumes: env: SCRIPT_DIR; deps: resolve_script_path.
# Computes: absolute CLI root path.
# Returns: prints root path.
# ---------------------------------------------------------------------
cli_resolve_root() {
    if [[ -n "${SCRIPT_DIR:-}" ]]; then
        printf "%s" "$SCRIPT_DIR"
        return 0
    fi
    local resolved=""
    if declare -F resolve_script_path >/dev/null 2>&1; then
        resolved="$(resolve_script_path "$0" 2>/dev/null || true)"
    fi
    if [[ -z "$resolved" ]]; then
        resolved="$0"
    fi
    printf "%s" "$(cd "$(dirname "$resolved")" && pwd)"
}

# ---------------------------------------------------------------------
# cli_parse_version_file()
# Read VERSION metadata from the CLI root.
# Consumes: args: root, out assoc name.
# Computes: version line + parsed branch/commit.
# Returns: 0 on success, 1 if no VERSION file.
# ---------------------------------------------------------------------
cli_parse_version_file() {
    local root="$1"
    local out_name="$2"
    [[ -z "$root" || -z "$out_name" ]] && return 1
    # shellcheck disable=SC2034
    local -n out_ref="$out_name"

    local version=""
    local version_branch=""
    local version_commit=""
    if [ ! -r "$root/VERSION" ]; then
        return 1
    fi
    version="$(<"$root/VERSION")"
    version_commit="$(printf "%s" "$version" | sed -nE 's/.*commit[:= ]+([0-9a-fA-F]{7,40}).*/\1/p' | head -n1)"
    if [[ -z "$version_commit" && "$version" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        version_commit="$version"
    fi
    version_branch="$(printf "%s" "$version" | sed -nE 's/.*branch[:= ]+([^ ]+).*/\1/p' | head -n1)"
    [[ "$version_branch" == "unknown" ]] && version_branch=""
    [[ "$version_commit" == "unknown" ]] && version_commit=""

    out_ref[version]="$version"
    out_ref[version_branch]="$version_branch"
    out_ref[version_commit]="$version_commit"
    return 0
}

# ---------------------------------------------------------------------
# cli_detect_install_mode()
# Determine install mode from env or path heuristics.
# Consumes: args: root; env: INM_SELF_INSTALL_MODE, INM_BASE_DIRECTORY, XDG_DATA_HOME, HOME.
# Computes: mode string.
# Returns: prints install mode.
# ---------------------------------------------------------------------
cli_detect_install_mode() {
    local root="$1"
    local mode="unknown"
    if [ -n "${INM_SELF_INSTALL_MODE:-}" ]; then
        case "${INM_SELF_INSTALL_MODE}" in
            1|system) mode="system" ;;
            2|local|user) mode="user" ;;
            3|project) mode="project" ;;
        esac
    fi
    if [ "$mode" = "unknown" ]; then
        local user_data_home="${XDG_DATA_HOME:-${HOME%/}/.local/share}"
        user_data_home="${user_data_home%/}"
        local user_dir_default="${user_data_home}/inmanage"
        local project_dir_default=""
        if [[ -n "${INM_BASE_DIRECTORY:-}" ]]; then
            project_dir_default="${INM_BASE_DIRECTORY%/}/.inmanage/cli"
        fi
        if [[ "$root" == "/usr/local/share/inmanage" ]]; then
            mode="system"
        elif [[ -n "${HOME:-}" && "$root" == "$user_dir_default" ]]; then
            mode="user"
        elif [[ -n "${INM_BASE_DIRECTORY:-}" && "$root" == "$project_dir_default" ]]; then
            mode="project"
        elif [[ -n "${INM_BASE_DIRECTORY:-}" && "$root" == "${INM_BASE_DIRECTORY%/}"* ]]; then
            mode="project"
        fi
    fi
    printf "%s" "$mode"
}

# ---------------------------------------------------------------------
# cli_collect_mtime_info()
# Collect mtime details for CLI files.
# Consumes: args: root, out assoc name; tools: stat/find.
# Computes: newest file + inmanage.sh mtime.
# Returns: 0 after populating fields (best-effort).
# ---------------------------------------------------------------------
cli_collect_mtime_info() {
    local root="$1"
    local out_name="$2"
    [[ -z "$root" || -z "$out_name" ]] && return 1
    # shellcheck disable=SC2034
    local -n out_ref="$out_name"

    local inmanage_mtime="" inmanage_mtime_short=""
    if [ -f "$root/inmanage.sh" ]; then
        inmanage_mtime=$(stat -c '%y' "$root/inmanage.sh" 2>/dev/null || stat -f '%Sm' "$root/inmanage.sh" 2>/dev/null || true)
        inmanage_mtime_short="$(printf "%s" "$inmanage_mtime" | cut -d. -f1)"
    fi
    out_ref[inmanage_mtime]="$inmanage_mtime"
    out_ref[inmanage_mtime_short]="$inmanage_mtime_short"

    if command -v find >/dev/null 2>&1; then
        local latest_ts="" latest_file="" latest_human=""
        while IFS= read -r -d '' f; do
            local ts human
            if ts=$(stat -c '%Y' "$f" 2>/dev/null); then
                human=$(stat -c '%y' "$f" 2>/dev/null || true)
            elif ts=$(stat -f '%m' "$f" 2>/dev/null); then
                human=$(stat -f '%Sm' "$f" 2>/dev/null || true)
            else
                continue
            fi
            if [[ -z "$latest_ts" || "$ts" -gt "$latest_ts" ]]; then
                latest_ts="$ts"
                latest_file="$f"
                latest_human="$human"
            fi
        done < <(find "$root" -path "$root/.git" -prune -o -type f -print0 2>/dev/null)
        if [ -n "$latest_file" ]; then
            local rel_latest="$latest_file"
            [[ "$latest_file" == "$root/"* ]] && rel_latest="${latest_file#"$root"/}"
            out_ref[newest_file]="$rel_latest"
            out_ref[newest_mtime]="$latest_human"
            out_ref[newest_mtime_short]="$(printf "%s" "$latest_human" | cut -d. -f1)"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------
# cli_collect_info()
# Collect CLI metadata into an assoc array.
# Consumes: args: out assoc name, optional root; env: INM_SELF_INSTALL_MODE, INM_BASE_DIRECTORY.
# Computes: root/version/git/install/mtime fields.
# Returns: 0 after populating out assoc.
# ---------------------------------------------------------------------
cli_collect_info() {
    local out_name="$1"
    local root_in="${2:-}"
    [[ -z "$out_name" ]] && return 1
    # shellcheck disable=SC2034
    local -n out="$out_name"
    out=()

    local root="$root_in"
    if [[ -z "$root" ]]; then
        root="$(cli_resolve_root)"
    fi
    out[root]="$root"

    cli_parse_version_file "$root" "$out_name" || true

    local git_present=false
    local branch="" commit="" dirty="" commit_date="" git_err=""
    local version_branch="${out[version_branch]:-}"
    local version_commit="${out[version_commit]:-}"
    if [ -e "$root/.git" ]; then
        git_present=true
        git_collect_info "$root" branch commit dirty commit_date git_err || true
    fi
    out[git_present]="$git_present"
    if [[ "$git_present" == true ]]; then
        if [[ -n "$version_branch" && ( -z "$branch" || "$branch" == "unknown" ) ]]; then
            branch="$version_branch"
        fi
        if [[ -n "$version_commit" && ( -z "$commit" || "$commit" == "unknown" ) ]]; then
            commit="$version_commit"
        fi
        [[ -z "$branch" ]] && branch="unknown"
        [[ -z "$commit" ]] && commit="unknown"
        out[branch]="$branch"
        out[commit]="$commit"
        out[dirty]="$dirty"
        out[commit_date]="$commit_date"
        out[git_error]="$git_err"
    fi
    if [[ "$git_present" != true && ( -n "$version_branch" || -n "$version_commit" ) ]]; then
        out[branch]="${version_branch:-unknown}"
        out[commit]="${version_commit:-unknown}"
    fi

    out[install_mode]="$(cli_detect_install_mode "$root")"
    cli_collect_mtime_info "$root" "$out_name" || true
    return 0
}
