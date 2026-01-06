#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HELPER_GIT_UTILS_LOADED:-} ]] && return
__HELPER_GIT_UTILS_LOADED=1

# ---------------------------------------------------------------------
# git_collect_info()
# Collect branch/commit/dirty/date from a git checkout.
# Consumes: args: root, out vars; tools: git.
# Computes: branch, commit short, dirty flag, commit date.
# Returns: 0 on success, 1 if git/checkout missing.
# ---------------------------------------------------------------------
git_collect_info() {
    local root="$1"
    local branch_var="$2"
    local commit_var="$3"
    local dirty_var="$4"
    local date_var="$5"
    local err_var="$6"

    local branch=""
    local commit=""
    local dirty=""
    local commit_date=""
    local err=""
    local out rc
    local git_dir=""
    local fallback_used=false

    local have_git=false
    if command -v git >/dev/null 2>&1; then
        have_git=true
    fi
    if [ ! -e "$root/.git" ]; then
        return 1
    fi
    if [[ "$have_git" == true ]]; then
        out="$(git -c safe.directory="$root" -C "$root" rev-parse --abbrev-ref HEAD 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            branch="$out"
        else
            err="$out"
        fi

        out="$(git -c safe.directory="$root" -C "$root" rev-parse --short HEAD 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            commit="$out"
        elif [ -z "$err" ]; then
            err="$out"
        fi

        git -c safe.directory="$root" -C "$root" status --porcelain >/dev/null 2>&1 && \
            git -c safe.directory="$root" -C "$root" status --porcelain | grep -q . && dirty="*"

        commit_date="$(git -c safe.directory="$root" -C "$root" log -1 --format=%cd --date=iso 2>/dev/null || true)"
    else
        err="git not found"
    fi

    if [[ -z "$branch" || -z "$commit" ]]; then
        git_dir="$root/.git"
        if [ -f "$git_dir" ]; then
            local git_file
            git_file="$(cat "$git_dir" 2>/dev/null || true)"
            if [[ "$git_file" =~ ^gitdir:\ (.+)$ ]]; then
                git_dir="${BASH_REMATCH[1]}"
                [[ "$git_dir" != /* ]] && git_dir="$root/$git_dir"
            fi
        fi
        if [ -f "$git_dir/HEAD" ]; then
            local head ref ref_path ref_commit
            head="$(cat "$git_dir/HEAD" 2>/dev/null || true)"
            if [[ "$head" =~ ^ref:\ (.+)$ ]]; then
                ref="${BASH_REMATCH[1]}"
                ref_path="$git_dir/$ref"
                [[ -z "$branch" ]] && branch="${ref##refs/heads/}"
                if [ -f "$ref_path" ]; then
                    ref_commit="$(cat "$ref_path" 2>/dev/null || true)"
                elif [ -f "$git_dir/packed-refs" ]; then
                    ref_commit="$(awk -v ref="$ref" '$2==ref {print $1; exit}' "$git_dir/packed-refs")"
                fi
                if [[ -z "$commit" && -n "$ref_commit" ]]; then
                    commit="$ref_commit"
                    fallback_used=true
                fi
            else
                if [[ -z "$commit" && -n "$head" ]]; then
                    commit="$head"
                    fallback_used=true
                fi
            fi
        fi
    fi

    if [[ -n "$commit" && "${#commit}" -gt 7 ]]; then
        commit="${commit:0:7}"
    fi

    [[ -n "$branch_var" ]] && printf -v "$branch_var" "%s" "${branch:-unknown}"
    [[ -n "$commit_var" ]] && printf -v "$commit_var" "%s" "${commit:-unknown}"
    [[ -n "$dirty_var" ]] && printf -v "$dirty_var" "%s" "$dirty"
    [[ -n "$date_var" ]] && printf -v "$date_var" "%s" "$commit_date"
    if [[ -n "$err_var" ]]; then
        if [[ "$fallback_used" == true ]]; then
            printf -v "$err_var" "%s" "${err:-}"
        else
            printf -v "$err_var" "%s" "$err"
        fi
    fi
}

# ---------------------------------------------------------------------
# git_origin_url()
# Resolve origin remote URL for a git checkout.
# Consumes: args: root, out var; tools: git.
# Computes: origin URL string.
# Returns: 0 if found, 1 otherwise.
# ---------------------------------------------------------------------
git_origin_url() {
    local root="$1"
    local out_var="$2"
    local out=""
    if ! command -v git >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -e "$root/.git" ]; then
        return 1
    fi
    out="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
    if [ -n "$out" ]; then
        [[ -n "$out_var" ]] && printf -v "$out_var" "%s" "$out" || printf "%s" "$out"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# git_local_head()
# Resolve local HEAD commit hash.
# Consumes: args: root, out var; tools: git.
# Computes: full commit hash.
# Returns: 0 if found, 1 otherwise.
# ---------------------------------------------------------------------
git_local_head() {
    local root="$1"
    local out_var="$2"
    local out=""
    if ! command -v git >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -e "$root/.git" ]; then
        return 1
    fi
    out="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$out" ]; then
        [[ -n "$out_var" ]] && printf -v "$out_var" "%s" "$out" || printf "%s" "$out"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# git_remote_head()
# Resolve remote HEAD commit for a ref on origin.
# Consumes: args: root, ref, out var; tools: git.
# Computes: remote commit hash via ls-remote.
# Returns: 0 if found, 1 otherwise.
# ---------------------------------------------------------------------
git_remote_head() {
    local root="$1"
    local ref="${2:-HEAD}"
    local out_var="$3"
    local out=""
    if ! command -v git >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -e "$root/.git" ]; then
        return 1
    fi
    out="$(GIT_TERMINAL_PROMPT=0 git -C "$root" -c http.lowSpeedLimit=1 -c http.lowSpeedTime=5 \
        ls-remote --heads origin "$ref" 2>/dev/null | awk '{print $1}' | head -n1)"
    if [ -n "$out" ]; then
        [[ -n "$out_var" ]] && printf -v "$out_var" "%s" "$out" || printf "%s" "$out"
        return 0
    fi
    log debug "[GIT] Remote head unavailable for $root (ref=${ref})."
    return 1
}

# ---------------------------------------------------------------------
# git_pull_ff_only()
# Fast-forward pull for a git checkout.
# Consumes: args: root; tools: git.
# Computes: git pull --ff-only.
# Returns: git exit status.
# ---------------------------------------------------------------------
git_pull_ff_only() {
    local root="$1"
    if ! command -v git >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -e "$root/.git" ]; then
        return 1
    fi
    git -C "$root" pull --ff-only
}
