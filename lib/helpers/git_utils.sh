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

    local branch_val=""
    local commit_val=""
    local dirty_val=""
    local commit_date_val=""
    local err_val=""
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
            branch_val="$out"
        else
            err_val="$out"
        fi
        if [[ "$DEBUG" == true ]]; then
            log debug "[GIT] rev-parse --abbrev-ref HEAD rc=$rc out=$out"
        fi

        out="$(git -c safe.directory="$root" -C "$root" rev-parse --short HEAD 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            commit_val="$out"
        elif [ -z "$err_val" ]; then
            err_val="$out"
        fi
        if [[ "$DEBUG" == true ]]; then
            log debug "[GIT] rev-parse --short HEAD rc=$rc out=$out"
        fi

        if [[ -z "$branch_val" ]]; then
            out="$(git -c safe.directory="$root" -C "$root" symbolic-ref -q --short HEAD 2>&1)"
            rc=$?
            if [ "$rc" -eq 0 ]; then
                branch_val="$out"
            elif [ -z "$err_val" ]; then
                err_val="$out"
            fi
            if [[ "$DEBUG" == true ]]; then
                log debug "[GIT] symbolic-ref --short HEAD rc=$rc out=$out"
            fi
        fi

        if [[ -z "$commit_val" ]]; then
            out="$(git -c safe.directory="$root" -C "$root" log -1 --format=%H 2>&1)"
            rc=$?
            if [ "$rc" -eq 0 ]; then
                commit_val="$out"
            elif [ -z "$err_val" ]; then
                err_val="$out"
            fi
            if [[ "$DEBUG" == true ]]; then
                log debug "[GIT] log -1 --format=%H rc=$rc out=$out"
            fi
        fi

        git -c safe.directory="$root" -C "$root" status --porcelain >/dev/null 2>&1 && \
            git -c safe.directory="$root" -C "$root" status --porcelain | grep -q . && dirty_val="*"

        commit_date_val="$(git -c safe.directory="$root" -C "$root" log -1 --format=%cd --date=iso 2>/dev/null || true)"
    else
        err_val="git not found"
    fi

    if [[ -z "$branch_val" || -z "$commit_val" ]]; then
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
                [[ -z "$branch_val" ]] && branch_val="${ref##refs/heads/}"
                if [ -f "$ref_path" ]; then
                    ref_commit="$(cat "$ref_path" 2>/dev/null || true)"
                elif [ -f "$git_dir/packed-refs" ]; then
                    ref_commit="$(awk -v ref="$ref" '$2==ref {print $1; exit}' "$git_dir/packed-refs")"
                fi
                if [[ -z "$commit_val" && -n "$ref_commit" ]]; then
                    commit_val="$ref_commit"
                    fallback_used=true
                fi
            else
                if [[ -z "$commit_val" && -n "$head" ]]; then
                    commit_val="$head"
                    fallback_used=true
                fi
            fi
        fi
    fi

    if [[ -n "$commit_val" && "${#commit_val}" -gt 7 ]]; then
        commit_val="${commit_val:0:7}"
    fi

    if [[ "$DEBUG" == true && ( -z "$branch_val" || -z "$commit_val" ) ]]; then
        git_debug_report "$root"
    fi

    [[ -n "$branch_var" ]] && printf -v "$branch_var" "%s" "${branch_val:-unknown}"
    [[ -n "$commit_var" ]] && printf -v "$commit_var" "%s" "${commit_val:-unknown}"
    [[ -n "$dirty_var" ]] && printf -v "$dirty_var" "%s" "$dirty_val"
    [[ -n "$date_var" ]] && printf -v "$date_var" "%s" "$commit_date_val"
    if [[ -n "$err_var" ]]; then
        if [[ "$fallback_used" == true ]]; then
            printf -v "$err_var" "%s" "${err_val:-}"
        else
            printf -v "$err_var" "%s" "$err_val"
        fi
    fi
}

# ---------------------------------------------------------------------
# git_debug_report()
# Emit detailed diagnostics for git collection issues.
# Consumes: args: root; tools: git, id, ls.
# Returns: 0 always.
# ---------------------------------------------------------------------
git_debug_report() {
    local root="$1"
    local user="" uid="" gid="" git_bin="" git_ver=""
    user="$(id -un 2>/dev/null || true)"
    uid="$(id -u 2>/dev/null || true)"
    gid="$(id -g 2>/dev/null || true)"
    git_bin="$(command -v git 2>/dev/null || true)"
    if [[ -n "$git_bin" ]]; then
        git_ver="$(git --version 2>/dev/null || true)"
    fi
    log debug "[GIT] Debug: user=${user:-unknown} uid=${uid:-?} gid=${gid:-?}"
    log debug "[GIT] Debug: root=${root} git_bin=${git_bin:-missing} git_ver=${git_ver:-unknown}"
    log debug "[GIT] Debug: GIT_DIR=${GIT_DIR:-} GIT_WORK_TREE=${GIT_WORK_TREE:-}"
    if [[ -d "$root/.git" || -f "$root/.git" ]]; then
        local perms=""
        perms="$(ls -ld "$root" "$root/.git" "$root/.git/HEAD" 2>/dev/null | tr '\n' '; ' || true)"
        [[ -n "$perms" ]] && log debug "[GIT] Debug: perms=${perms}"
    else
        log debug "[GIT] Debug: .git missing at ${root}/.git"
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
