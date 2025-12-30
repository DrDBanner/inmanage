#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_PREFLIGHT_LOADED:-} ]] && return
__SERVICE_PREFLIGHT_LOADED=1

# ---------------------------------------------------------------------
# run_preflight()
# Performs environment checks for inmanage/Invoice Ninja.
# Flags via NAMED_ARGS:
#   --checks=TAG1,TAG2  Only run selected check groups (e.g., CLI,SYS,FS,DB,WEB,PHP,EXT,NET,MAIL,APP,CRON,SNAPPDF)
#   --exclude=TAG1,TAG2 Skip selected check groups.
# ---------------------------------------------------------------------
run_preflight() {
    local errexit_set=false
    if [[ $- == *e* ]]; then
        errexit_set=true
        set +e
    fi
    local -A ARGS=()
    parse_named_args ARGS "$@"
    local pf_label="${INM_PREFLIGHT_LABEL:-PREFLIGHT}"
    local enforced_owner=""
    local enforced_user="${ENFORCED_USER:-${INM_ENFORCED_USER:-}}"
    if [ -n "$enforced_user" ]; then
        local enforced_group="${INM_ENFORCED_GROUP:-}"
        if [ -z "$enforced_group" ]; then
            enforced_group="$(id -gn "$enforced_user" 2>/dev/null || true)"
            [[ -z "$enforced_group" ]] && enforced_group="$enforced_user"
        fi
        enforced_owner="${enforced_user}:${enforced_group}"
    fi
    local fast="${ARGS[fast]:-false}"
    local skip_snappdf="${ARGS[skip_snappdf]:-false}"
    local skip_github="${ARGS[skip_github]:-false}"
    local cli_config_present=false
    if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "${INM_SELF_ENV_FILE:-}" ]; then
        cli_config_present=true
    fi
    local current_user
    current_user="$(id -un 2>/dev/null || true)"
    local can_enforce=false
    if [ -n "$enforced_user" ] && { [ "$EUID" -eq 0 ] || [ "$current_user" = "$enforced_user" ]; }; then
        can_enforce=true
    fi
    INM_PREFLIGHT_CAN_ENFORCE="$can_enforce"
    local preflight_cleanup_enabled=false
    if [ "$cli_config_present" != true ]; then
        preflight_cleanup_enabled=true
    fi
    local -a preflight_created_dirs=()
    preflight_track_created_dir() {
        local dir="$1"
        local existing
        for existing in "${preflight_created_dirs[@]}"; do
            [[ "$existing" == "$dir" ]] && return 0
        done
        preflight_created_dirs+=("$dir")
    }
# shellcheck disable=SC2329
preflight_cleanup_created_dirs() {
        if [[ "$preflight_cleanup_enabled" != true ]]; then
            return 0
        fi
        local i dir
        for ((i=${#preflight_created_dirs[@]}-1; i>=0; i--)); do
            dir="${preflight_created_dirs[i]}"
            if rmdir "$dir" 2>/dev/null; then
                log debug "[PREFLIGHT] Removed temp dir: $dir"
            fi
        done
    }
    trap preflight_cleanup_created_dirs RETURN

    # Optional check filter (CSV of tags, e.g., CLI,SYS,FS,DB,WEB,PHP,EXT,NET,MAIL,APP,CRON,SNAPPDF,PERM)
    normalize_check_tag() {
        local raw="$1"
        local tag="${raw^^}"
        tag="${tag//[^A-Z0-9]/}"
        case "$tag" in
            CLI) echo "CLI" ;;
            SYS|SYSTEM) echo "SYS" ;;
            FS|FILESYSTEM|DISK) echo "FS" ;;
            ENVCLI|ENVCL|CLICONFIG) echo "ENVCLI" ;;
            ENVAPP|APPENV) echo "ENVAPP" ;;
            CMD|COMMAND|COMMANDS|TOOLS|CLICMD|CLICMDS|CLICOMMAND|CLICOMMANDS) echo "CMD" ;;
            WEB|WEBSERVER) echo "WEB" ;;
            PHP) echo "PHP" ;;
            EXT|EXTENSIONS|PHPEXT) echo "EXT" ;;
            WEBPHP|WEBPH) echo "WEBPHP" ;;
            NET|NETWORK|DNS) echo "NET" ;;
            MAIL|SMTP|EMAIL) echo "MAIL" ;;
            DB|DATABASE|MYSQL|MARIADB) echo "DB" ;;
            APP|APPLICATION) echo "APP" ;;
            PERM|PERMISSION|PERMISSIONS) echo "PERM" ;;
            CRON|SCHEDULER) echo "CRON" ;;
            SNAPPDF|SNAPDF|PDF) echo "SNAPPDF" ;;
            *) echo "" ;;
        esac
    }

    mem_to_mb() {
        local val="$1"
        if [[ "$val" =~ ^-?[0-9]+$ ]]; then
            echo "$val"
            return
        fi
        if [[ "$val" =~ ^([0-9]+)([KkMmGg])$ ]]; then
            local mem_val="${BASH_REMATCH[1]}"
            local mem_unit="${BASH_REMATCH[2]}"
            case "$mem_unit" in
                K|k) echo $((mem_val / 1024));;
                M|m) echo "$mem_val";;
                G|g) echo $((mem_val * 1024));;
            esac
            return
        fi
        echo ""
    }

    local -A allowed_args=(
        [checks]=1
        [check]=1
        [exclude]=1
        [exclude_checks]=1
        [exclude-checks]=1
        [notify_test]=1
        [notify-test]=1
        [notify_heartbeat]=1
        [notify-heartbeat]=1
        [fix_permissions]=1
        [debug]=1
        [dry_run]=1
        [force]=1
        [override_enforced_user]=1
        [user]=1
        [no_cli_clear]=1
        [fast]=1
        [skip_snappdf]=1
        [skip_github]=1
    )
    local -A unknown_args=()
    local arg_key
    for arg_key in "${!ARGS[@]}"; do
        if [[ -z "${allowed_args[$arg_key]:-}" ]]; then
            unknown_args["$arg_key"]=1
        fi
    done
    if declare -p NAMED_ARGS >/dev/null 2>&1; then
        for arg_key in "${!NAMED_ARGS[@]}"; do
            if [[ -z "${allowed_args[$arg_key]:-}" ]]; then
                unknown_args["$arg_key"]=1
            fi
        done
    fi
    if (( ${#unknown_args[@]} > 0 )); then
        local -a bad_args=()
        for arg_key in "${!unknown_args[@]}"; do
            bad_args+=("--${arg_key//_/-}")
        done
        log err "[${pf_label}] Unknown arguments: ${bad_args[*]}"
        log info "[${pf_label}] Allowed flags: --checks=TAG1,TAG2 --check=TAG1,TAG2 --exclude=TAG1,TAG2 --fix-permissions --notify-test --notify-heartbeat --debug --dry-run --override-enforced-user --no-cli-clear --fast --skip-snappdf --skip-github"
        $errexit_set && set -e
        return 1
    fi

    # prefer globally parsed NAMED_ARGS to survive re-exec user switches
    local fix_permissions
    fix_permissions="$(args_get ARGS "false" fix_permissions)"
    local checks_filter
    checks_filter="$(args_get ARGS "" checks check)"
    local exclude_filter
    exclude_filter="$(args_get ARGS "" exclude exclude_checks)"
    local notify_test
    notify_test="$(args_get ARGS "false" notify_test)"
    local notify_heartbeat
    notify_heartbeat="$(args_get ARGS "false" notify_heartbeat)"
    if args_is_true "$fix_permissions"; then
        fix_permissions=true
    else
        fix_permissions=false
    fi
    if args_is_true "$notify_test"; then
        notify_test=true
    else
        notify_test=false
    fi
    if args_is_true "$notify_heartbeat"; then
        notify_heartbeat=true
    else
        notify_heartbeat=false
    fi
    if [[ "$notify_heartbeat" == true ]]; then
        if [[ -n "${INM_NOTIFY_HEARTBEAT_INCLUDE:-}" && -z "$checks_filter" ]]; then
            checks_filter="${INM_NOTIFY_HEARTBEAT_INCLUDE}"
        fi
        if [[ -n "${INM_NOTIFY_HEARTBEAT_EXCLUDE:-}" ]]; then
            if [[ -z "$exclude_filter" ]]; then
                exclude_filter="${INM_NOTIFY_HEARTBEAT_EXCLUDE}"
            else
                exclude_filter="${exclude_filter},${INM_NOTIFY_HEARTBEAT_EXCLUDE}"
            fi
        fi
    fi
    if [ "$fix_permissions" = true ] && [ -z "$checks_filter" ]; then
        checks_filter="APP,PERM"
    fi
    declare -A PF_ALLOW=()
    declare -A PF_DENY=()
    local -a unknown_checks=()
    if [[ -n "$checks_filter" ]]; then
        IFS=',' read -ra tmp_checks <<<"$checks_filter"
        for c in "${tmp_checks[@]}"; do
            local norm
            norm="$(normalize_check_tag "$c")"
            if [[ -n "$norm" ]]; then
                PF_ALLOW["${norm}"]=1
            else
                unknown_checks+=("$c")
            fi
        done
        if [[ ${#PF_ALLOW[@]} -eq 0 ]]; then
            log err "[${pf_label}] No valid check tags in --checks=$checks_filter"
            log info "[${pf_label}] Valid tags: CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,MAIL,DB,APP,CRON,SNAPPDF,PERM"
            $errexit_set && set -e
            return 1
        fi
        log debug "[${pf_label}] Checks filter active: $checks_filter"
    fi
    if [[ -n "$exclude_filter" ]]; then
        IFS=',' read -ra tmp_exclude <<<"$exclude_filter"
        for c in "${tmp_exclude[@]}"; do
            local norm
            norm="$(normalize_check_tag "$c")"
            if [[ -n "$norm" ]]; then
                PF_DENY["${norm}"]=1
            else
                unknown_checks+=("$c")
            fi
        done
        log debug "[${pf_label}] Exclude filter active: $exclude_filter"
    fi
    if [[ ${#unknown_checks[@]} -gt 0 ]]; then
        log err "[${pf_label}] Unknown check tags: ${unknown_checks[*]}"
        log info "[${pf_label}] Valid tags: CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,MAIL,DB,APP,CRON,SNAPPDF,PERM"
        $errexit_set && set -e
        return 1
    fi

    should_run() {
        local tag="$1"
        if [[ -n "${PF_DENY[$tag]:-}" ]]; then
            return 1
        fi
        if [[ -z "$checks_filter" ]]; then
            return 0
        fi
        [[ -n "${PF_ALLOW[$tag]:-}" ]]
    }

    # Results collector
    local -a PF_STATUS=()
    local -a PF_CHECK=()
    local -a PF_DETAIL=()
    add_result() {
        local tag="$2"
        if [[ -n "$checks_filter" && -z "${PF_ALLOW[$tag]:-}" ]]; then
            return 0
        fi
        PF_STATUS+=("$1")
        PF_CHECK+=("$2")
        PF_DETAIL+=("$3")
        case "$1" in
            OK)   ((ok++));;
            WARN) ((warn++));;
            ERR)  ((err++));;
            *)    ;;
        esac
    }

    local ok=0 warn=0 err=0
    local phpv=""
    log info "[${pf_label}] Starting system checks"

    # Mandatory CLI command check (fail-fast message)
    local req_cmds=(php git curl tar rsync zip unzip composer jq awk sed find xargs touch tee sha256sum)
    if should_run "CMD"; then
        local -a missing_cmds=()
        for cmd in "${req_cmds[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                missing_cmds+=("$cmd")
            fi
        done
        if [ ${#missing_cmds[@]} -gt 0 ]; then
            log err "[${pf_label}] Missing required CLI commands: ${missing_cmds[*]}"
            log info "[${pf_label}] Please install missing commands to proceed."
            $errexit_set && set -e
            return 1
        fi
    fi

    if declare -F spinner_start >/dev/null 2>&1; then
        spinner_start "Running ${pf_label} checks..."
    fi

    if should_run "CLI"; then
    # ---- CLI self info ----
    local cli_root cli_branch cli_commit cli_dirty=""
    local cli_version="" cli_version_commit=""
    cli_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    add_result INFO "CLI" "CLI: $cli_root"
    if [ -r "$cli_root/VERSION" ]; then
        cli_version=$(<"$cli_root/VERSION")
        cli_version_commit="$(printf "%s" "$cli_version" | sed -nE 's/.*commit[:= ]+([0-9a-fA-F]{7,40}).*/\1/p' | head -n1)"
        if [[ -z "$cli_version_commit" ]] && printf "%s" "$cli_version" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then
            cli_version_commit="$cli_version"
        fi
    fi
    if command -v git >/dev/null 2>&1 && [ -d "$cli_root/.git" ]; then
        local git_err="" git_out="" git_rc=0
        git_out="$(git -C "$cli_root" rev-parse --abbrev-ref HEAD 2>&1)"
        git_rc=$?
        if [ "$git_rc" -eq 0 ]; then
            cli_branch="$git_out"
        else
            git_err="$git_out"
        fi
        git_out="$(git -C "$cli_root" rev-parse --short HEAD 2>&1)"
        git_rc=$?
        if [ "$git_rc" -eq 0 ]; then
            cli_commit="$git_out"
        else
            [[ -z "$git_err" ]] && git_err="$git_out"
        fi
        git -C "$cli_root" status --porcelain >/dev/null 2>&1 && \
            git -C "$cli_root" status --porcelain | grep -q . && cli_dirty="*"
        if [[ -z "$cli_commit" && -n "$cli_version_commit" ]]; then
            cli_commit="$cli_version_commit"
        fi
        cli_branch="${cli_branch:-unknown}"
        cli_commit="${cli_commit:-unknown}"
        add_result INFO "CLI" "Source: git checkout (branch=${cli_branch} commit=${cli_commit}${cli_dirty})"
        if echo "$git_err" | grep -qi "dubious ownership"; then
            add_result WARN "CLI" "Git ownership check blocked access. Fix: git config --global --add safe.directory $cli_root"
        elif echo "$git_err" | grep -qi "permission denied"; then
            add_result WARN "CLI" "Git metadata not readable at $cli_root (try: sudo or adjust ownership)."
        fi
        local cli_commit_date
        cli_commit_date="$(git -C "$cli_root" log -1 --format=%cd --date=iso 2>/dev/null || true)"
        [[ -n "$cli_commit_date" ]] && add_result INFO "CLI" "Last commit date: $cli_commit_date"
    else
        add_result WARN "CLI" "Source: no git metadata (tarball/snapshot install)"
    fi
    # Optional VERSION file in repo root
    if [ -n "$cli_version" ]; then
        add_result INFO "CLI" "Version file: ${cli_version}"
    fi
    # Detect install mode for CLI
    local cli_install_mode="unknown"
    if [ -n "${INM_SELF_INSTALL_MODE:-}" ]; then
        case "${INM_SELF_INSTALL_MODE}" in
            1|system) cli_install_mode="system" ;;
            2|local|user) cli_install_mode="user" ;;
            3|project) cli_install_mode="project" ;;
        esac
    fi
    if [ "$cli_install_mode" = "unknown" ]; then
        local user_data_home="${XDG_DATA_HOME:-${HOME%/}/.local/share}"
        user_data_home="${user_data_home%/}"
        local user_dir_default="${user_data_home}/inmanage"
        local project_dir_default=""
        if [[ -n "${INM_BASE_DIRECTORY:-}" ]]; then
            project_dir_default="${INM_BASE_DIRECTORY%/}/.inmanage/cli"
        fi
        if [[ "$cli_root" == "/usr/local/share/inmanage" ]]; then
            cli_install_mode="system"
        elif [[ -n "${HOME:-}" && "$cli_root" == "$user_dir_default" ]]; then
            cli_install_mode="user"
        elif [[ -n "${INM_BASE_DIRECTORY:-}" && "$cli_root" == "$project_dir_default" ]]; then
            cli_install_mode="project"
        elif [[ -n "${INM_BASE_DIRECTORY:-}" && "$cli_root" == "${INM_BASE_DIRECTORY%/}"* ]]; then
            cli_install_mode="project"
        fi
    fi
    add_result INFO "CLI" "Install mode: ${cli_install_mode} (switch with: inm self switch-mode)"
    # Newest file mtime (best-effort)
    local inmanage_mtime="" inmanage_mtime_short=""
    if [ -f "$cli_root/inmanage.sh" ]; then
        inmanage_mtime=$(stat -c '%y' "$cli_root/inmanage.sh" 2>/dev/null || stat -f '%Sm' "$cli_root/inmanage.sh" 2>/dev/null)
        inmanage_mtime_short="$(echo "$inmanage_mtime" | cut -d. -f1)"
    fi

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
        done < <(find "$cli_root" -path "$cli_root/.git" -prune -o -type f -print0 2>/dev/null)
        if [ -n "$latest_file" ]; then
            local rel_latest="$latest_file"
            [[ "$latest_file" == "$cli_root/"* ]] && rel_latest="${latest_file#"$cli_root"/}"
            local latest_short
            latest_short="$(echo "$latest_human" | cut -d. -f1)"
            add_result INFO "CLI" "Newest file mtime: ${latest_short} (${rel_latest})"
            if [ -n "$inmanage_mtime_short" ] && [ "$latest_file" != "$cli_root/inmanage.sh" ]; then
                add_result INFO "CLI" "inmanage.sh modified: $inmanage_mtime_short"
            fi
        elif [ -n "$inmanage_mtime_short" ]; then
            add_result INFO "CLI" "inmanage.sh modified: $inmanage_mtime_short"
        fi
    fi

    fi
    if should_run "SYS"; then
    # ---- System details ----
    local host os kernel arch cpu memtotal=""
    host="$(hostname 2>/dev/null || true)"
    kernel="$(uname -r 2>/dev/null || true)"
    arch="$(uname -m 2>/dev/null || true)"
    cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || true)"
    if [ -f /proc/meminfo ]; then
        memtotal=$(awk '/MemTotal/ {printf "%.1fG", $2/1024/1024}' /proc/meminfo 2>/dev/null)
    elif command -v sysctl >/dev/null 2>&1; then
        local mem_bytes=""
        mem_bytes="$(sysctl -n hw.physmem 2>/dev/null || true)"
        if ! [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
            mem_bytes="$(sysctl -n hw.physmem64 2>/dev/null || true)"
        fi
        if [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
            memtotal=$(awk -v b="$mem_bytes" 'BEGIN {printf "%.1fG", b/1024/1024/1024}')
        fi
    fi
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os="${PRETTY_NAME:-$NAME $VERSION_ID}"
    elif command -v freebsd-version >/dev/null 2>&1; then
        os="FreeBSD $(freebsd-version 2>/dev/null | head -n1)"
    elif command -v uname >/dev/null 2>&1; then
        local os_name os_release
        os_name="$(uname -s 2>/dev/null || true)"
        os_release="$(uname -r 2>/dev/null || true)"
        if [ -n "$os_name" ] && [ -n "$os_release" ]; then
            os="${os_name} ${os_release}"
        else
            os="${os_name:-unknown}"
        fi
    fi
    add_result INFO "SYS" "Host: ${host:-unknown} | OS: ${os:-unknown}"
    add_result INFO "SYS" "Kernel: ${kernel:-?} | Arch: ${arch:-?} | CPU cores: ${cpu:-?} | RAM: ${memtotal:-unknown}"
    resolve_primary_ip4() {
        local ip=""
        if command -v ip >/dev/null 2>&1; then
            ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
        fi
        if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
            ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./) {print $i; exit}}')
        fi
        if [ -z "$ip" ] && command -v route >/dev/null 2>&1; then
            local iface=""
            iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
            if [ -z "$iface" ]; then
                iface=$(route -n get -inet default 2>/dev/null | awk '/interface:/{print $2; exit}')
            fi
            if [ -z "$iface" ]; then
                iface=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}')
            fi
            if [ -n "$iface" ] && command -v ifconfig >/dev/null 2>&1; then
                ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2; exit}')
            fi
            if [ -z "$ip" ]; then
                ip=$(route -n get default 2>/dev/null | awk '/if address:/{print $3; exit}')
            fi
        fi
        if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
            ip=$(ifconfig 2>/dev/null | awk '/inet / {for(i=1;i<=NF;i++){if($i=="inet"){print $(i+1); exit} if($i ~ /^addr:/){sub(/^addr:/,"",$i); print $i; exit}}}')
        fi
        if [[ "$ip" == 127.* || "$ip" == 0.0.0.0 ]]; then
            ip=""
        fi
        printf "%s" "$ip"
    }
    resolve_primary_ip6() {
        local ip6=""
        if command -v ip >/dev/null 2>&1; then
            ip6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
        fi
        if [ -z "$ip6" ] && command -v hostname >/dev/null 2>&1; then
            ip6=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /:/ && $i !~ /^fe80:/) {print $i; exit}}')
        fi
        if [ -z "$ip6" ] && command -v ifconfig >/dev/null 2>&1; then
            ip6=$(ifconfig 2>/dev/null | awk '/inet6 / {for(i=1;i<=NF;i++){if($i=="inet6"){print $(i+1); exit} if($i ~ /^addr:/){sub(/^addr:/,"",$i); print $i; exit}}}' | awk '$1 !~ /^fe80:/ {print $1; exit}')
        fi
        printf "%s" "$ip6"
    }
    local ip4 ip6
    ip4="$(resolve_primary_ip4)"
    ip6="$(resolve_primary_ip6)"
    if [ -n "$ip4" ]; then
        add_result INFO "SYS" "IPv4: $ip4"
    else
        add_result INFO "SYS" "IPv4: not detected"
    fi
    if [ -n "$ip6" ]; then
        add_result INFO "SYS" "IPv6: $ip6"
    else
        add_result INFO "SYS" "IPv6: not detected"
    fi
    # Container/virt hint
    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt --container 2>/dev/null)
        [[ "$virt" == "none" ]] && virt=""
    fi
    if [ -z "$virt" ] && [ -f /proc/1/cgroup ]; then
        grep -qiE 'docker|lxc|podman' /proc/1/cgroup && virt="container"
    fi
    if [ -n "$virt" ]; then
        add_result INFO "SYS" "Container detected: ${virt}"
    else
        add_result INFO "SYS" "Container: not detected"
    fi
    fi

    # Hydrate APP_URL from app .env if missing
    if should_run "NET" || should_run "WEBPHP"; then
        if [ -z "${APP_URL:-}" ] && [ -f "${INM_ENV_FILE:-}" ]; then
            local app_url
            app_url=$(grep -E '^APP_URL=' "$INM_ENV_FILE" 2>/dev/null | head -n1 | sed -E 's/^APP_URL=//' | tr -d '"'\'' ')
            if [ -n "$app_url" ]; then
                APP_URL="$app_url"
            fi
        fi
    fi

    if should_run "WEB"; then
    # ---- Webserver detection ----
    local web_is_apache=false
    local apache_running=false
    local nginx_running=false
    local apache_bin=""
    if pgrep -x apache2 >/dev/null 2>&1 || pgrep -x apache24 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1 || pgrep -x apache >/dev/null 2>&1; then
        apache_running=true
    elif pgrep -f 'apache24|apache2|httpd' >/dev/null 2>&1; then
        apache_running=true
    fi
    if pgrep -x nginx >/dev/null 2>&1; then
        nginx_running=true
    elif pgrep -f 'nginx' >/dev/null 2>&1; then
        nginx_running=true
    fi
    if [[ "$apache_running" != true && "$nginx_running" != true ]] && command -v service >/dev/null 2>&1; then
        if service -e 2>/dev/null | grep -q '/apache24$'; then
            apache_running=true
        elif service -e 2>/dev/null | grep -q '/nginx$'; then
            nginx_running=true
        fi
    fi
    if [[ "$apache_running" == true ]]; then
        for bin in apache2 httpd apache /usr/local/sbin/httpd /usr/local/apache2/bin/httpd; do
            if [[ "$bin" == /* ]]; then
                [[ -x "$bin" ]] && apache_bin="$bin" && break
            elif command -v "$bin" >/dev/null 2>&1; then
                apache_bin="$bin"
                break
            fi
        done
        local av=""
        if [ -n "$apache_bin" ]; then
            av=$("$apache_bin" -v 2>/dev/null | awk -F: '/Server version/{print $2}' | xargs)
        fi
        add_result INFO "WEB" "Apache${av:+ $av}"
        web_is_apache=true
    elif [[ "$nginx_running" == true ]]; then
        local nv
        nv=$(nginx -v 2>&1 | cut -d: -f2- | xargs)
        add_result INFO "WEB" "Nginx${nv:+ $nv}"
    else
        add_result WARN "WEB" "Webserver not detected"
    fi
    # php-fpm presence
    if pgrep -f "php-fpm" >/dev/null 2>&1; then
        add_result INFO "WEB" "php-fpm running"
    fi
    # Apache-specific: htaccess presence in public
    if [ "$web_is_apache" = true ]; then
        local public_htaccess="${INM_INSTALLATION_PATH%/}/public/.htaccess"
        if [ -f "$public_htaccess" ]; then
            add_result OK "WEB" ".htaccess present in public"
        else
            add_result WARN "WEB" ".htaccess missing in public (Apache detected)"
        fi
    fi
    # Ports 80/443 listening (best-effort)
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ":80 " && add_result INFO "WEB" "Port 80 open"
        ss -lnt 2>/dev/null | grep -q ":443 " && add_result INFO "WEB" "Port 443 open"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -q ":80 " && add_result INFO "WEB" "Port 80 open"
        netstat -lnt 2>/dev/null | grep -q ":443 " && add_result INFO "WEB" "Port 443 open"
    fi
    fi

    if should_run "CMD" || should_run "DB" || should_run "APP"; then
    # ---- Command availability ----
    local db_cmds_required=false
    local db_config_present=false
    if [[ -n "${DB_HOST:-}" || -n "${DB_USERNAME:-}" || -n "${DB_DATABASE:-}" ]]; then
        db_cmds_required=true
        db_config_present=true
    else
        local env_for_db=""
        if [ -n "${INM_ENV_FILE:-}" ]; then
            env_for_db="$(expand_path_vars "$INM_ENV_FILE")"
        elif [ -n "${INM_INSTALLATION_PATH:-}" ]; then
            env_for_db="${INM_INSTALLATION_PATH%/}/.env"
        fi
        if [ -n "$env_for_db" ] && [ -f "$env_for_db" ]; then
            if grep -qE '^DB_(HOST|USERNAME|DATABASE)=' "$env_for_db" 2>/dev/null; then
                db_cmds_required=true
                db_config_present=true
            fi
        fi
    fi
    local db_scope_note=""
    local db_missing_status="ERR"
    if [ "$db_cmds_required" != true ]; then
        db_scope_note=" (DB not configured)"
        db_missing_status="WARN"
    fi

    local have_mysql=false
    local have_mariadb=false
    local have_mysqldump=false
    local have_mariadb_dump=false
    command -v mysql >/dev/null 2>&1 && have_mysql=true
    command -v mariadb >/dev/null 2>&1 && have_mariadb=true
    command -v mysqldump >/dev/null 2>&1 && have_mysqldump=true
    command -v mariadb-dump >/dev/null 2>&1 && have_mariadb_dump=true

    local db_client=""
    local db_dump=""
    local db_client_note=""
    if [ "$have_mysql" = true ] && [ "$have_mariadb" != true ]; then
        db_client="mysql"
    elif [ "$have_mariadb" = true ] && [ "$have_mysql" != true ]; then
        db_client="mariadb"
    elif [ "$have_mysql" = true ] && [ "$have_mariadb" = true ]; then
        db_client="mysql"
        if [ -n "${INM_DB_CLIENT:-}" ]; then
            case "${INM_DB_CLIENT,,}" in
                mysql|mariadb)
                    db_client="${INM_DB_CLIENT,,}"
                    db_client_note=" (INM_DB_CLIENT)"
                    ;;
                *)
                    add_result WARN "CMD" "INM_DB_CLIENT ignored (use mysql or mariadb)"
                    ;;
            esac
        else
            if [ "$db_config_present" != true ]; then
                db_client_note=" (both installed; DB not configured)"
            else
                db_client_note=" (both installed)"
            fi
        fi
    fi

    if [ "$db_client" = "mariadb" ] && [ "$have_mariadb_dump" = true ]; then
        db_dump="mariadb-dump"
    elif [ "$db_client" = "mysql" ] && [ "$have_mysqldump" = true ]; then
        db_dump="mysqldump"
    elif [ "$have_mysqldump" = true ]; then
        db_dump="mysqldump"
    elif [ "$have_mariadb_dump" = true ]; then
        db_dump="mariadb-dump"
    fi

    if should_run "CMD"; then
        for cmd in "${req_cmds[@]}"; do
            if command -v "$cmd" >/dev/null 2>&1; then
                add_result OK "CMD" "$cmd"
            else
                add_result ERR "CMD" "$cmd missing"
            fi
        done
    fi

    if [ "$have_mysql" = true ] || [ "$have_mariadb" = true ]; then
        if [ "$have_mysql" = true ] && [ "$have_mariadb" = true ]; then
            add_result OK "CMD" "DB client: ${db_client:-mysql}${db_client_note} (mysql + mariadb available)"
        else
            add_result OK "CMD" "DB client: ${db_client:-mysql}${db_client_note}"
        fi
    else
        add_result "$db_missing_status" "CMD" "DB client missing (need mysql or mariadb)${db_scope_note}"
    fi

    if [ "$have_mysqldump" = true ] || [ "$have_mariadb_dump" = true ]; then
        if [ "$have_mysqldump" = true ] && [ "$have_mariadb_dump" = true ]; then
            add_result OK "CMD" "DB dump: ${db_dump:-mysqldump} (mysqldump + mariadb-dump available)"
        else
            add_result OK "CMD" "DB dump: ${db_dump:-mysqldump}"
        fi
    else
        add_result "$db_missing_status" "CMD" "DB dump tool missing (need mysqldump or mariadb-dump)${db_scope_note}"
    fi
    fi

    if should_run "APP"; then
    # ---- App sanity & permissions ----
    local app_cfg_hint=""
    if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "${INM_SELF_ENV_FILE:-}" ]; then
        app_cfg_hint="CLI config: ${INM_SELF_ENV_FILE}"
    fi
    if [ -n "${INM_ENV_FILE:-}" ] && [ -f "${INM_ENV_FILE:-}" ]; then
        if [ -n "$app_cfg_hint" ]; then
            app_cfg_hint+=" | App env: ${INM_ENV_FILE}"
        else
            app_cfg_hint="App env: ${INM_ENV_FILE}"
        fi
    fi
    if [ -n "${INM_INSTALLATION_PATH:-}" ] && [ -d "${INM_INSTALLATION_PATH%/}" ]; then
        local app_dir="${INM_INSTALLATION_PATH%/}"

        local app_missing=()
        local app_warn=()
        [[ -f "${app_dir}/artisan" ]] || app_missing+=("artisan")
        [[ -f "${app_dir}/vendor/autoload.php" ]] || app_missing+=("vendor/autoload.php")
        [[ -f "${app_dir}/public/index.php" ]] || app_missing+=("public/index.php")
        [[ -f "${app_dir}/.env" ]] || app_missing+=(".env")
        [[ -d "${app_dir}/storage" ]] || app_missing+=("storage/")
        [[ -d "${app_dir}/public" ]] || app_missing+=("public/")
        [[ -d "${app_dir}/routes" ]] || app_warn+=("routes/")
        [[ -d "${app_dir}/resources/views" ]] || app_warn+=("resources/views/")
        [[ -d "${app_dir}/database" ]] || app_warn+=("database/")
        [[ -f "${app_dir}/public/.htaccess" ]] || app_warn+=("public/.htaccess")
        [[ -d "${app_dir}/bootstrap/cache" ]] || app_warn+=("bootstrap/cache/")
        [[ -f "${app_dir}/composer.json" ]] || app_warn+=("composer.json")
        [[ -f "${app_dir}/VERSION.txt" ]] || app_warn+=("VERSION.txt")

        if [[ ${#app_missing[@]} -gt 0 ]]; then
            add_result ERR "APP" "Critical app items missing: ${app_missing[*]}"
            if [ -n "$app_cfg_hint" ]; then
            add_result WARN "APP" "Config found (${app_cfg_hint}) but app tree is missing/incomplete. Fix: move existing app to ${app_dir} or run 'inm core install --provision' (recommended). For guidance, run 'inm core install --help'."
            fi
        else
            add_result OK "APP" "App structure looks complete at ${app_dir}"
            if [[ ${#app_warn[@]} -gt 0 ]]; then
                add_result WARN "APP" "Non-critical items missing: ${app_warn[*]}"
            fi
        fi

        if [ -n "${APP_URL:-}" ] && command -v curl >/dev/null 2>&1; then
            local app_url_trim status_code
            app_url_trim="${APP_URL%/}"
            status_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$app_url_trim")"
            if [[ "$status_code" == "000" && "$app_url_trim" == https:* ]]; then
                status_code="$(curl -s -k -o /dev/null -w '%{http_code}' --connect-timeout 5 "$app_url_trim")"
            fi
            if [[ "$status_code" == "200" ]]; then
                add_result OK "APP" "APP_URL returns 200 OK (${app_url_trim})"
            elif [[ "$status_code" =~ ^3 ]]; then
                add_result WARN "APP" "APP_URL redirects (HTTP ${status_code}): ${app_url_trim}"
            elif [[ "$status_code" == "000" ]]; then
                add_result WARN "APP" "APP_URL not reachable (no HTTP response): ${app_url_trim}"
            else
                add_result ERR "APP" "APP_URL returned HTTP ${status_code}: ${app_url_trim}"
            fi
        fi

        if [ -n "$enforced_user" ]; then
            local expected_group="${INM_ENFORCED_GROUP:-}"
            if [ -z "$expected_group" ]; then
                expected_group="$(id -gn "$enforced_user" 2>/dev/null || true)"
                [[ -z "$expected_group" ]] && expected_group="$enforced_user"
            fi
            local expected_owner="${enforced_user}:${expected_group}"
            local dir_mode="${INM_DIR_MODE:-750}"
            local file_mode="${INM_FILE_MODE:-640}"
            local env_mode="${INM_ENV_MODE:-600}"
            check_owner_and_fix() {
                local p="$1"
                [ ! -e "$p" ] && return
                local owner
                owner=$(stat -c '%U:%G' "$p" 2>/dev/null || stat -f '%Su:%Sg' "$p" 2>/dev/null || echo "")
                if [ -n "$owner" ] && [ "$owner" != "$expected_owner" ]; then
                    if [ "$fix_permissions" = true ]; then
                        if [ "$EUID" -eq 0 ]; then
                            add_result WARN "PERM" "Fixing ownership for $p (was $owner -> $expected_owner)"
                            enforce_ownership "$p"
                        else
                            add_result WARN "PERM" "Ownership mismatch at $p (owner=$owner, expected=$expected_owner). Run: sudo chown -R ${expected_owner} \"$p\""
                        fi
                    else
                        add_result WARN "PERM" "Ownership mismatch at $p (owner=$owner, expected=$expected_owner). Use --fix-permissions to repair."
                    fi
                else
                    add_result OK "PERM" "$p owned by ${owner:-unknown}"
                fi
            }
            local perm_paths=()
            if [ -n "${INM_BASE_DIRECTORY:-}" ]; then
                perm_paths+=("${INM_BASE_DIRECTORY%/}")
            fi
            if [ -n "${INM_BACKUP_DIRECTORY:-}" ]; then
                perm_paths+=("$(expand_path_vars "$INM_BACKUP_DIRECTORY")")
            fi
            if [ -n "${INM_CACHE_LOCAL_DIRECTORY:-}" ]; then
                perm_paths+=("$(expand_path_vars "$INM_CACHE_LOCAL_DIRECTORY")")
            fi
            if [ -n "${INM_CACHE_GLOBAL_DIRECTORY:-}" ]; then
                perm_paths+=("$(expand_path_vars "$INM_CACHE_GLOBAL_DIRECTORY")")
            fi
            perm_paths+=("${INM_INSTALLATION_PATH%/}")
            perm_paths+=("${INM_INSTALLATION_PATH%/}/storage")
            perm_paths+=("${INM_INSTALLATION_PATH%/}/public")
            for p in "${perm_paths[@]}"; do
                check_owner_and_fix "$p"
            done

            check_mode_and_fix_dir() {
                local p="$1"
                [ ! -d "$p" ] && return
                local current
                current="$(_fs_get_mode "$p")"
                if [ -n "$current" ] && [ "$current" != "$dir_mode" ]; then
                    if [ "$fix_permissions" = true ]; then
                        add_result WARN "PERM" "Fixing dir mode for $p (was $current -> $dir_mode)"
                        enforce_dir_permissions "$dir_mode" "$p"
                    else
                        add_result WARN "PERM" "Dir mode mismatch at $p (mode=$current, expected=$dir_mode). Use --fix-permissions to repair."
                    fi
                fi
            }
            check_mode_and_fix_dir "${INM_INSTALLATION_PATH%/}"
            check_mode_and_fix_dir "${INM_INSTALLATION_PATH%/}/storage"
            check_mode_and_fix_dir "${INM_INSTALLATION_PATH%/}/public"
            check_mode_and_fix_dir "${INM_INSTALLATION_PATH%/}/bootstrap/cache"

            local file_mode_applied=false
            if [ -f "${INM_INSTALLATION_PATH%/}/public/index.php" ]; then
                local current_file_mode
                current_file_mode="$(_fs_get_mode "${INM_INSTALLATION_PATH%/}/public/index.php")"
                if [ -n "$current_file_mode" ] && [ "$current_file_mode" != "$file_mode" ]; then
                    if [ "$fix_permissions" = true ]; then
                        add_result WARN "PERM" "Fixing file modes under app dir (target $file_mode)"
                        enforce_file_permissions "$file_mode" "${INM_INSTALLATION_PATH%/}"
                        file_mode_applied=true
                    else
                        add_result WARN "PERM" "File mode mismatch (public/index.php=$current_file_mode, expected=$file_mode). Use --fix-permissions to repair."
                    fi
                fi
            fi
            if [ "$fix_permissions" = true ] && [ "$file_mode_applied" = false ]; then
                enforce_file_permissions "$file_mode" "${INM_INSTALLATION_PATH%/}"
            fi

            if [ -f "${INM_INSTALLATION_PATH%/}/.env" ]; then
                local current_env_mode
                current_env_mode="$(_fs_get_mode "${INM_INSTALLATION_PATH%/}/.env")"
                if [ -n "$current_env_mode" ] && [ "$current_env_mode" != "$env_mode" ]; then
                    if [ "$fix_permissions" = true ]; then
                        add_result WARN "PERM" "Fixing .env mode (was $current_env_mode -> $env_mode)"
                        enforce_file_mode "$env_mode" "${INM_INSTALLATION_PATH%/}/.env"
                    else
                        add_result WARN "PERM" ".env mode mismatch (mode=$current_env_mode, expected=$env_mode). Use --fix-permissions to repair."
                    fi
                fi
            fi
        fi
    else
        add_result WARN "APP" "App directory missing or unset: ${INM_INSTALLATION_PATH:-<unset>}"
        if [ -n "$app_cfg_hint" ]; then
            add_result WARN "APP" "Config found (${app_cfg_hint}) but app directory is missing. Fix: move app to ${INM_INSTALLATION_PATH%/} or run 'inm core install --provision'. Help: 'inm core install --help' or docs."
        fi
    fi
    fi

    if should_run "PHP" || should_run "EXT" || should_run "WEBPHP"; then
    # ---- PHP version / ini ----
    local cli_php_out
    cli_php_out="$(phpinfo_probe_cli)" || true
    if [ -z "$cli_php_out" ]; then
        if should_run "PHP"; then
            add_result ERR "PHP" "php CLI not available"
        fi
        if should_run "EXT"; then
            add_result ERR "EXT" "php CLI not available"
        fi
    else
        if should_run "PHP"; then
            local phpv cli_ini cli_ini_scan_dir cli_ini_scanned cli_sapi cli_user_ini
            local mem inputvars opc max_exec max_input_time post_max upload_max realpath_cache display_errors error_reporting
            local cli_proc_open cli_exec cli_fpassthru cli_open_basedir cli_disable_functions
            while IFS='=' read -r key val; do
                case "$key" in
                    PHP_VERSION) phpv="$val" ;;
                    PHP_INI) cli_ini="$val" ;;
                    PHP_INI_SCAN_DIR) cli_ini_scan_dir="$val" ;;
                    PHP_INI_SCANNED) cli_ini_scanned="$val" ;;
                    PHP_SAPI) cli_sapi="$val" ;;
                    USER_INI) cli_user_ini="$val" ;;
                    MEMORY_LIMIT) mem="$val" ;;
                    MAX_INPUT_VARS) inputvars="$val" ;;
                    OPCACHE) opc="$val" ;;
                    MAX_EXEC) max_exec="$val" ;;
                    MAX_INPUT_TIME) max_input_time="$val" ;;
                    POST_MAX) post_max="$val" ;;
                    UPLOAD_MAX) upload_max="$val" ;;
                    REALPATH_CACHE_SIZE) realpath_cache="$val" ;;
                    DISPLAY_ERRORS) display_errors="$val" ;;
                    ERROR_REPORTING) error_reporting="$val" ;;
                    PROC_OPEN) cli_proc_open="$val" ;;
                    EXEC) cli_exec="$val" ;;
                    FPASSTHRU) cli_fpassthru="$val" ;;
                    OPEN_BASEDIR) cli_open_basedir="$val" ;;
                    DISABLE_FUNCTIONS) cli_disable_functions="$val" ;;
                esac
            done <<< "$cli_php_out"
            add_result OK "PHP" "CLI ${phpv:-unknown}"
            if printf '%s\n' "$phpv" "8.1.0" | sort -V | head -n1 | grep -qx "8.1.0"; then
                add_result OK "PHP" ">= 8.1"
            else
                add_result ERR "PHP" "Needs >= 8.1"
            fi
            [[ -n "$cli_sapi" ]] && add_result INFO "PHP" "SAPI ${cli_sapi}"
            add_result INFO "PHP" "php.ini ${cli_ini:-<none>}"
            [[ -n "$cli_ini_scan_dir" ]] && add_result INFO "PHP" "ini scan dir ${cli_ini_scan_dir}"
            if [[ -n "$cli_ini_scanned" ]]; then
                local cli_ini_short
                cli_ini_short="$(shorten_ini_scanned "$cli_ini_scanned")"
                add_result INFO "PHP" "ini scanned ${cli_ini_short}"
            fi
            local cli_user_ini_detail="${cli_user_ini:-<none>}"
            add_result INFO "PHP" ".user.ini ${cli_user_ini_detail}"
            php_thresholds add_result "PHP" "$mem" "$inputvars" "$opc" "$max_exec" "$max_input_time" "$post_max" "$upload_max" "$realpath_cache" "$display_errors" "$error_reporting" "$cli_proc_open" "$cli_exec" "$cli_fpassthru" "$cli_open_basedir" "$cli_disable_functions"
        fi

        if should_run "EXT"; then
            # Extensions
            local exts=(bcmath ctype curl fileinfo gd gmp iconv imagick intl mbstring mysqli openssl pdo_mysql soap tokenizer xml zip)
            for ext in "${exts[@]}"; do
                if php -m | grep -qi "^$ext$"; then
                    add_result OK "EXT" "$ext"
                else
                    add_result ERR "EXT" "$ext missing"
                fi
            done

            local saxon_loaded=""
            saxon_loaded="$(php -r 'echo extension_loaded("saxon") ? "1" : "0";' 2>/dev/null || true)"
            if [[ "$saxon_loaded" == "1" ]]; then
                add_result OK "EXT" "saxon"
            else
                local saxon_path=""
                local ext_dir=""
                ext_dir="$(php -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
                if [[ -n "$ext_dir" && -f "${ext_dir%/}/saxon.so" ]]; then
                    saxon_path="${ext_dir%/}/saxon.so"
                fi
                if [[ -z "$saxon_path" ]]; then
                    saxon_path="$(find /usr/lib /usr/local/lib -type f -path "*/php/*/saxon.so" 2>/dev/null | head -n1 || true)"
                fi
                if [[ -n "$saxon_path" ]]; then
                    add_result INFO "EXT" "saxon present but not loaded: ${saxon_path}"
                else
                    add_result INFO "EXT" "saxon not installed (XSLT2). See: https://invoiceninja.github.io/en/self-host-installation/#lib-saxon"
                fi
            fi
        fi
    fi
    fi

    # ---- Web PHP check ----
    if should_run "WEBPHP"; then
        check_web_php "$phpv" add_result
    fi

    if should_run "FS"; then
    # ---- Filesystem perms ----
    if [ -n "${INM_BASE_DIRECTORY:-}" ] && df -h "$INM_BASE_DIRECTORY" >/dev/null 2>&1; then
        local diskline=""
        local df_out="" used="" avail="" mount=""
        df_out="$(df -hP "$INM_BASE_DIRECTORY" 2>/dev/null | awk 'NR==2{print $3" "$4" "$6}')" || true
        read -r used avail mount <<<"$df_out"
        if [[ "$used" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]]; then
            df_out="$(df -h "$INM_BASE_DIRECTORY" 2>/dev/null | awk 'NR==2{print $3" "$4" "$6}')" || true
            read -r used avail mount <<<"$df_out"
        fi
        if [[ -n "$used" && -n "$avail" && -n "$mount" ]]; then
            diskline="avail:${avail} used:${used} mount:${mount}"
            add_result INFO "FS" "$diskline (Disk @base)"
        fi
    fi
    # Base, app, backup directories
    local fs_items=()
    if [ "$cli_config_present" = true ]; then
        fs_items=(
            "$INM_BASE_DIRECTORY|Base dir"
            "$INM_INSTALLATION_PATH|App dir"
            "$INM_BACKUP_DIRECTORY|Backup dir"
        )
    else
        add_result INFO "FS" "Not installed (yet) – base/app/backup checks skipped (CLI config missing)"
    fi
    fs_du_timeout() {
        local dir="$1"
        local base=5
        local max=120
        local extra=0
        local normalized_dir="${dir%/}"
        local base_dir="${INM_BASE_DIRECTORY%/}"
        if [ -n "$base_dir" ] && [ -n "$normalized_dir" ] && [ "$normalized_dir" = "$base_dir" ]; then
            if [ -d "$dir" ]; then
                local count_base
                count_base=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$count_base" =~ ^[0-9]+$ ]]; then
                    extra="$count_base"
                fi
            fi
        fi
        if [ -n "${INM_BACKUP_DIRECTORY:-}" ] && [ "$dir" = "$INM_BACKUP_DIRECTORY" ]; then
            if [ -d "$dir" ]; then
                local count
                count=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$count" =~ ^[0-9]+$ ]]; then
                    extra="$count"
                fi
            fi
        fi
        local timeout=$((base + extra))
        if [ "$timeout" -gt "$max" ]; then
            timeout="$max"
        fi
        printf "%s" "$timeout"
    }
    for entry in "${fs_items[@]}"; do
        local dir label
        dir="${entry%%|*}"
        label="${entry#*|}"
        [ -z "$dir" ] && continue
        local created_dir=false
        if [[ ! -d "$dir" ]]; then
            if mkdir -p "$dir" 2>/dev/null; then
                created_dir=true
                preflight_track_created_dir "$dir"
            fi
        fi
        if [[ "$created_dir" == true && "$can_enforce" == true ]]; then
            if declare -F enforce_ownership >/dev/null 2>&1; then
                enforce_ownership "$dir"
            fi
            if [[ -n "${INM_DIR_MODE:-}" ]] && declare -F enforce_dir_permissions >/dev/null 2>&1; then
                enforce_dir_permissions "$INM_DIR_MODE" "$dir"
            fi
        fi
        local sz=""
        local base_dir="${INM_BASE_DIRECTORY%/}"
        if [ -d "$dir" ] && command -v du >/dev/null 2>&1; then
            if command -v timeout >/dev/null 2>&1; then
                local du_timeout du_out du_rc=0
                du_timeout="$(fs_du_timeout "$dir")"
                local errexit_set=false
                [[ $- == *e* ]] && errexit_set=true
                set +e
                du_out=$(timeout "$du_timeout" du -sh "$dir" 2>/dev/null)
                du_rc=$?
                $errexit_set && set -e
                if [ "$du_rc" -eq 0 ]; then
                    sz=$(echo "$du_out" | awk '{print $1}')
                elif [ "$du_rc" -eq 124 ]; then
                    log debug "[FS] Size check timed out for $dir; skipping size."
                fi
            else
                sz=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            fi
        fi
        if [[ -z "$sz" && -n "$base_dir" && "${dir%/}" == "$base_dir" ]] && command -v du >/dev/null 2>&1; then
            local base_out base_rc=0
            local errexit_set=false
            [[ $- == *e* ]] && errexit_set=true
            set +e
            base_out=$(du -sh "$dir" 2>/dev/null)
            base_rc=$?
            $errexit_set && set -e
            if [ "$base_rc" -eq 0 ]; then
                sz=$(echo "$base_out" | awk '{print $1}')
            fi
        fi
        local created_note=""
        if [[ "$created_dir" == true ]]; then
            if [[ "$preflight_cleanup_enabled" == true ]]; then
                created_note=" (created by preflight; removed after check)"
            else
                created_note=" (created by preflight)"
            fi
        fi
        if touch "$dir/.inm_perm_test" 2>/dev/null; then
            rm -f "$dir/.inm_perm_test"
            local detail="Writable: $dir ($label)${created_note}"
            [[ -n "$sz" ]] && detail+=" (Size: $sz)"
            add_result OK "FS" "$detail"
        else
            local hint="$label not writable: $dir${created_note}"
            if [ -n "${enforced_owner:-}" ]; then
                hint+=" (hint: chown -R ${enforced_owner} \"$dir\" or run 'inm core health --fix-permissions')"
            fi
            add_result ERR "FS" "$hint"
        fi
    done

    # Cache directories first
    local cache_global_state="unset"
    local cache_local_state="unset"
    local cache_global_detail=""
    local cache_local_detail=""
    local cache_global_world_writable=false
    local cache_local_world_writable=false
    local cache_global_mode=""
    local cache_local_mode=""

    if [ -n "${INM_CACHE_GLOBAL_DIRECTORY:-}" ]; then
        local gc_path gc_parent
        gc_path="$(expand_path_vars "$INM_CACHE_GLOBAL_DIRECTORY")"
        gc_parent="$(dirname "$gc_path")"
        if [[ -d "$gc_parent" ]]; then
            :
        else
            mkdir -p "$gc_parent" 2>/dev/null || true
        fi
        local gc_created=false
        if [[ ! -d "$gc_path" ]]; then
            mkdir -p "$gc_path" 2>/dev/null && gc_created=true
        fi
        if [[ "$gc_created" == true ]]; then
            preflight_track_created_dir "$gc_path"
        fi
        if [[ "$gc_created" == true && "$can_enforce" == true ]]; then
            if declare -F enforce_ownership >/dev/null 2>&1; then
                enforce_ownership "$gc_path"
            fi
            if declare -F apply_cache_dir_mode >/dev/null 2>&1; then
                apply_cache_dir_mode "$gc_path"
            fi
        fi
        if touch "$gc_path/.inm_perm_test" 2>/dev/null; then
            rm -f "$gc_path/.inm_perm_test"
            cache_global_state="ok"
            if [[ "$gc_created" == true ]]; then
                if [[ "$preflight_cleanup_enabled" == true ]]; then
                    cache_global_detail="Writable: $gc_path (Cache global) (created by preflight; removed after check)"
                else
                    cache_global_detail="Writable: $gc_path (Cache global) (created by preflight)"
                fi
            else
                cache_global_detail="Writable: $gc_path (Cache global)"
            fi
            local gc_size=""
            if command -v du >/dev/null 2>&1; then
                if command -v timeout >/dev/null 2>&1; then
                    local du_out du_rc=0
                    local errexit_set=false
                    [[ $- == *e* ]] && errexit_set=true
                    set +e
                    du_out=$(timeout 5 du -sh "$gc_path" 2>/dev/null)
                    du_rc=$?
                    $errexit_set && set -e
                    if [ "$du_rc" -eq 0 ]; then
                        gc_size=$(echo "$du_out" | awk '{print $1}')
                    elif [ "$du_rc" -eq 124 ]; then
                        log debug "[FS] Cache global size check timed out; skipping size."
                    fi
                else
                    gc_size=$(du -sh "$gc_path" 2>/dev/null | awk '{print $1}')
                fi
            fi
            [[ -n "$gc_size" ]] && cache_global_detail+=" (Size: $gc_size)"
            cache_global_mode="$(_fs_get_mode "$gc_path")"
            if [[ -n "$cache_global_mode" ]]; then
                local other=$((cache_global_mode % 10))
                if (( (other & 2) != 0 )); then
                    cache_global_world_writable=true
                fi
            fi
        else
            cache_global_state="fail"
            cache_global_detail="Not writable: $gc_path (Cache global)"
            if [ -n "${enforced_owner:-}" ]; then
                cache_global_detail+=" (hint: chown -R ${enforced_owner} \"$gc_path\" or use --override_enforced_user=true to adjust perms)"
            fi
            cache_global_detail+=" or set INM_CACHE_GLOBAL_DIRECTORY to an accessible path."
        fi
    fi

    if [ -n "${INM_CACHE_LOCAL_DIRECTORY:-}" ]; then
        local lc_path
        lc_path="$(expand_path_vars "$INM_CACHE_LOCAL_DIRECTORY")"
        local lc_created=false
        if [[ ! -d "$lc_path" ]]; then
            mkdir -p "$lc_path" 2>/dev/null && lc_created=true
        fi
        if [[ "$lc_created" == true ]]; then
            preflight_track_created_dir "$lc_path"
        fi
        if [[ "$lc_created" == true && "$can_enforce" == true ]]; then
            if declare -F enforce_ownership >/dev/null 2>&1; then
                enforce_ownership "$lc_path"
            fi
            if declare -F apply_cache_dir_mode >/dev/null 2>&1; then
                apply_cache_dir_mode "$lc_path"
            fi
        fi
        if touch "$lc_path/.inm_perm_test" 2>/dev/null; then
            rm -f "$lc_path/.inm_perm_test"
            cache_local_state="ok"
            if [[ "$lc_created" == true ]]; then
                if [[ "$preflight_cleanup_enabled" == true ]]; then
                    cache_local_detail="Writable: $lc_path (Cache local) (created by preflight; removed after check)"
                else
                    cache_local_detail="Writable: $lc_path (Cache local) (created by preflight)"
                fi
            else
                cache_local_detail="Writable: $lc_path (Cache local)"
            fi
            local lc_size=""
            if command -v du >/dev/null 2>&1; then
                if command -v timeout >/dev/null 2>&1; then
                    local du_out du_rc=0
                    local errexit_set=false
                    [[ $- == *e* ]] && errexit_set=true
                    set +e
                    du_out=$(timeout 5 du -sh "$lc_path" 2>/dev/null)
                    du_rc=$?
                    $errexit_set && set -e
                    if [ "$du_rc" -eq 0 ]; then
                        lc_size=$(echo "$du_out" | awk '{print $1}')
                    elif [ "$du_rc" -eq 124 ]; then
                        log debug "[FS] Cache local size check timed out; skipping size."
                    fi
                else
                    lc_size=$(du -sh "$lc_path" 2>/dev/null | awk '{print $1}')
                fi
            fi
            [[ -n "$lc_size" ]] && cache_local_detail+=" (Size: $lc_size)"
            cache_local_mode="$(_fs_get_mode "$lc_path")"
            if [[ -n "$cache_local_mode" ]]; then
                local other=$((cache_local_mode % 10))
                if (( (other & 2) != 0 )); then
                    cache_local_world_writable=true
                fi
            fi
        else
            cache_local_state="fail"
            cache_local_detail="Not writable: $lc_path (Cache local)"
            if [ -n "${enforced_owner:-}" ]; then
                cache_local_detail+=" (hint: chown -R ${enforced_owner} \"$lc_path\" or use --override_enforced_user=true to adjust perms)"
            fi
            cache_local_detail+=" or set INM_CACHE_LOCAL_DIRECTORY to an accessible path."
        fi
    fi

    local cache_any_ok=false
    if [ "$cache_global_state" = "ok" ] || [ "$cache_local_state" = "ok" ]; then
        cache_any_ok=true
    fi

    if [ "$cache_global_state" = "ok" ]; then
        add_result OK "FS" "$cache_global_detail"
        if [ "$cache_global_world_writable" = true ]; then
            add_result WARN "FS" "Cache global is world-writable: $gc_path (mode=$cache_global_mode). Consider 775 with shared group or 750."
        fi
    elif [ "$cache_global_state" = "fail" ]; then
        if [ "$cache_any_ok" = true ]; then
            add_result INFO "FS" "${cache_global_detail} (local cache writable; consider fixing global cache for shared use)"
        else
            add_result ERR "FS" "${cache_global_detail} (no writable cache directories)"
        fi
    fi

    if [ "$cache_local_state" = "ok" ]; then
        add_result OK "FS" "$cache_local_detail"
        if [ "$cache_local_world_writable" = true ]; then
            add_result WARN "FS" "Cache local is world-writable: $lc_path (mode=$cache_local_mode). Consider 775 with shared group or 750."
        fi
    elif [ "$cache_local_state" = "fail" ]; then
        if [ "$cache_any_ok" = true ]; then
            add_result INFO "FS" "${cache_local_detail} (global cache writable; consider fixing local cache for speed)"
        else
            add_result ERR "FS" "${cache_local_detail} (no writable cache directories)"
        fi
    fi
    fi

    # ---- ENV (CLI / APP) ----
    if should_run "ENVCLI"; then
        if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "$INM_SELF_ENV_FILE" ]; then
            local cli_keys=(INM_ENFORCED_USER INM_BASE_DIRECTORY INM_INSTALLATION_DIRECTORY INM_BACKUP_DIRECTORY INM_CACHE_GLOBAL_DIRECTORY INM_CACHE_LOCAL_DIRECTORY)
            for k in "${cli_keys[@]}"; do
                local v="${!k}"
                add_result INFO "ENVCLI" "${k}=${v:-<unset>}"
            done
            local notify_keys=(
                INM_NOTIFY_ENABLED
                INM_NOTIFY_TARGETS
                INM_NOTIFY_EMAIL_TO
                INM_NOTIFY_EMAIL_FROM
                INM_NOTIFY_EMAIL_FROM_NAME
                INM_NOTIFY_LEVEL
                INM_NOTIFY_NONINTERACTIVE_ONLY
                INM_NOTIFY_SMTP_TIMEOUT
                INM_NOTIFY_HOOKS_ENABLED
                INM_NOTIFY_HOOKS_FAILURE
                INM_NOTIFY_HOOKS_SUCCESS
                INM_NOTIFY_HEARTBEAT_ENABLED
                INM_NOTIFY_HEARTBEAT_TIME
                INM_NOTIFY_HEARTBEAT_LEVEL
                INM_NOTIFY_HEARTBEAT_INCLUDE
                INM_NOTIFY_HEARTBEAT_EXCLUDE
                INM_NOTIFY_WEBHOOK_URL
            )
            for k in "${notify_keys[@]}"; do
                local v="${!k}"
                case "$k" in
                    INM_NOTIFY_WEBHOOK_URL)
                        v="${v:+<set>}"
                        ;;
                esac
                add_result INFO "ENVCLI" "${k}=${v:-<unset>}"
            done
        else
            add_result WARN "ENVCLI" "Not installed (yet) – CLI env missing (${INM_SELF_ENV_FILE:-unset})"
        fi
    fi

    if should_run "ENVAPP"; then
        if [ -n "${INM_ENV_FILE:-}" ] && [ -f "$INM_ENV_FILE" ]; then
            local app_keys=(APP_NAME APP_URL PDF_GENERATOR APP_DEBUG)
            for k in "${app_keys[@]}"; do
                local v
                v=$(read_env_value "$INM_ENV_FILE" "$k")
                add_result INFO "ENVAPP" "${k}=${v:-<unset>}"
            done
        else
            add_result WARN "ENVAPP" "Not installed (yet) – app .env missing (${INM_ENV_FILE:-unset})"
        fi
    fi

    if should_run "DB" || should_run "APP"; then
    # Try to hydrate DB vars from app .env if missing
    if [ -z "${DB_HOST:-}" ] && [ -f "${INM_ENV_FILE:-}" ]; then
        if load_env_file_raw "$INM_ENV_FILE"; then
            add_result INFO "DB" "Loaded DB vars from ${INM_ENV_FILE}"
        else
            add_result WARN "DB" "Failed to parse DB vars from ${INM_ENV_FILE}"
        fi
    fi

    # ---- DB connectivity ----
    if [ -n "$DB_HOST" ] && [ -n "$DB_USERNAME" ]; then
        local db_port="${DB_PORT:-3306}"
        add_result INFO "DB" "Target: host=${DB_HOST} port=${db_port} db=${DB_DATABASE:-<unset>} user=${DB_USERNAME}"
        if [ -z "${db_client:-}" ]; then
            add_result ERR "DB" "No MySQL/MariaDB client available"
        elif "$db_client" -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "SELECT 1" >/dev/null 2>&1; then
            add_result INFO "DB" "Client: ${db_client}"
            add_result OK "DB" "Connection ok to $DB_HOST:${DB_PORT:-3306}"
            # Try to read server/version info
            local dbinfo
            dbinfo=$("$db_client" -N -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "select @@version, @@version_comment;" 2>/dev/null | head -n1)
            if [ -n "$dbinfo" ]; then
                add_result INFO "DB" "Server: $dbinfo"
            fi
            # DB settings (best effort)
            local settings
            settings=$("$db_client" -N -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "select @@innodb_file_per_table, @@max_allowed_packet, @@character_set_server, @@collation_server;" 2>/dev/null | head -n1)
            if [ -n "$settings" ]; then
                IFS=$'\t' read -r innodb packet charset coll <<<"$settings"
                add_result INFO "DB" "innodb_file_per_table=${innodb:-?}"
                add_result INFO "DB" "max_allowed_packet=${packet:-?}"
                add_result INFO "DB" "charset=${charset:-?} collation=${coll:-?}"
            fi
            local sql_mode
            sql_mode=$("$db_client" -N -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "select @@sql_mode;" 2>/dev/null | head -n1)
            [[ -n "$sql_mode" ]] && add_result INFO "DB" "sql_mode=${sql_mode}"
            if [ -n "$DB_DATABASE" ]; then
                if "$db_client" -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "USE \`$DB_DATABASE\`;" >/dev/null 2>&1; then
                    add_result OK "DB" "Database '$DB_DATABASE' exists."
                    local lang_table=""
                    if "$db_client" -N -B -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} \
                        -e "SELECT table_name FROM information_schema.tables WHERE table_schema='${DB_DATABASE}' AND table_name='languages' LIMIT 1;" 2>/dev/null | grep -q "^languages$"; then
                        lang_table="languages"
                    elif "$db_client" -N -B -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} \
                        -e "SELECT table_name FROM information_schema.tables WHERE table_schema='${DB_DATABASE}' AND table_name='language' LIMIT 1;" 2>/dev/null | grep -q "^language$"; then
                        lang_table="language"
                    fi

                    if [ -n "$lang_table" ]; then
                        local lang_count=""
                        lang_count=$("$db_client" -N -B -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} \
                            -e "SELECT COUNT(*) FROM \`${DB_DATABASE}\`.\`${lang_table}\`;" 2>/dev/null | head -n1)
                        if [[ "$lang_count" =~ ^[0-9]+$ ]]; then
                            if [ "$lang_count" -eq 0 ]; then
                                add_result ERR "APP" "Languages loaded: 0 (run ninja:translations + db:seed --class=LanguageSeeder)"
                            elif [ "$lang_count" -lt 10 ]; then
                                add_result WARN "APP" "Languages loaded: ${lang_count} (expected more; run ninja:translations + db:seed --class=LanguageSeeder)"
                            else
                                add_result OK "APP" "Languages loaded: ${lang_count}"
                            fi
                        else
                            add_result WARN "APP" "Languages count unavailable (query failed)"
                        fi
                    else
                        add_result WARN "APP" "Languages table missing; run migrations/seed (ninja:translations + db:seed --class=LanguageSeeder)"
                    fi
                else
                    local hint="Database '$DB_DATABASE' not found or no access."
                    hint+=" Set DB_ELEVATED_USERNAME/PASSWORD in .env.provision and rerun provision to create it."
                    add_result WARN "DB" "$hint"
                fi
            fi
        else
            local hint="Cannot connect to $DB_HOST:${DB_PORT:-3306} as $DB_USERNAME"
            hint+=" (check DB_ELEVATED_USERNAME/PASSWORD or credentials in .env/.env.provision)"
            add_result ERR "DB" "$hint"
        fi
    else
        local db_env_file=""
        if [ -n "${INM_ENV_FILE:-}" ]; then
            db_env_file="$(expand_path_vars "$INM_ENV_FILE")"
        elif [ -n "${INM_INSTALLATION_PATH:-}" ]; then
            db_env_file="${INM_INSTALLATION_PATH%/}/.env"
        fi
        if [ -n "$db_env_file" ] && [ -f "$db_env_file" ]; then
            add_result ERR "DB" "Missing DB_HOST/DB_USERNAME despite loaded .env"
        else
            add_result WARN "DB" "DB config not set; skipping connectivity checks"
        fi
    fi
    fi

    if should_run "CRON"; then
    # ---- Cron presence ----
    local cron_running=false
    if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || pgrep -x systemd >/dev/null 2>&1; then
        cron_running=true
    elif [[ -f /var/run/cron.pid || -f /var/run/crond.pid ]]; then
        cron_running=true
    elif command -v service >/dev/null 2>&1; then
        if service -e 2>/dev/null | grep -Eq '/cron$'; then
            cron_running=true
        fi
    fi
    if [[ "$cron_running" == true ]]; then
        add_result OK "CRON" "Scheduler service present"
    else
        add_result WARN "CRON" "No cron service detected"
    fi
    local cron_file="/etc/cron.d/invoiceninja"
    local cron_lines=""
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l >/dev/null 2>&1; then
            cron_lines="$(crontab -l 2>/dev/null)"
        fi
        if [[ -n "$enforced_user" && "$enforced_user" != "$current_user" ]]; then
            local enforced_cron=""
            if [[ $EUID -eq 0 ]]; then
                enforced_cron="$(crontab -l -u "$enforced_user" 2>/dev/null || true)"
            elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
                enforced_cron="$(sudo -n crontab -l -u "$enforced_user" 2>/dev/null || true)"
            fi
            if [[ -n "$enforced_cron" ]]; then
                cron_lines+=$'\n'"$enforced_cron"
            fi
        fi
    fi
    if [[ -r "$cron_file" ]]; then
        cron_lines+=$'\n'"$(cat "$cron_file")"
    fi
    local home_cronfile="${HOME:-}/cronfile"
    if [[ -r "$home_cronfile" ]]; then
        cron_lines+=$'\n'"$(cat "$home_cronfile")"
    fi
    if [[ -n "$enforced_user" && "$enforced_user" != "$current_user" ]]; then
        local enforced_home=""
        if command -v getent >/dev/null 2>&1; then
            enforced_home="$(getent passwd "$enforced_user" 2>/dev/null | cut -d: -f6)"
        fi
        if [[ -z "$enforced_home" ]]; then
            enforced_home="$(eval echo "~$enforced_user" 2>/dev/null || true)"
        fi
        if [[ -n "$enforced_home" && "$enforced_home" != "~$enforced_user" ]]; then
            local enforced_cronfile="${enforced_home%/}/cronfile"
            if [[ -r "$enforced_cronfile" ]]; then
                cron_lines+=$'\n'"$(cat "$enforced_cronfile")"
            fi
        fi
    fi
    local cron_scope="$cron_lines"
    local base_clean="${INM_BASE_DIRECTORY%/}"
    local app_clean="${INM_INSTALLATION_PATH%/}"
    if [ -n "$base_clean" ] || [ -n "$app_clean" ]; then
        escape_regex() {
            printf '%s' "$1" | sed -E 's/[][\\.^$*+?(){}|]/\\&/g'
        }
        local base_re="" app_re="" scope_re=""
        [ -n "$base_clean" ] && base_re="$(escape_regex "$base_clean")"
        [ -n "$app_clean" ] && app_re="$(escape_regex "$app_clean")"
        if [ -n "$base_re" ] && [ -n "$app_re" ]; then
            scope_re="${base_re}|${app_re}"
        else
            scope_re="${base_re}${app_re}"
        fi
        if [ -n "$scope_re" ]; then
            cron_scope="$(printf "%s\n" "$cron_lines" | grep -E "$scope_re" || true)"
        fi
    fi
    if echo "$cron_scope" | grep -q "artisan schedule:run"; then
        add_result OK "CRON" "artisan schedule:run present"
    else
        add_result WARN "CRON" "artisan schedule missing; run: inm core cron install --jobs=artisan"
    fi

    extract_cron_time() {
        local line="$1"
        local min hour
        min="$(awk '{print $1}' <<<"$line")"
        hour="$(awk '{print $2}' <<<"$line")"
        if [[ "$min" =~ ^[0-5]?[0-9]$ && "$hour" =~ ^([01]?[0-9]|2[0-3])$ ]]; then
            printf "%02d:%02d" "$hour" "$min"
        fi
    }
    if echo "$cron_scope" | grep -Eq "(inmanage(\.sh)?|inm(\.sh)?) core backup"; then
        local backup_line backup_time
        backup_line="$(echo "$cron_scope" | grep -E "(inmanage(\.sh)?|inm(\.sh)?) core backup" | head -n1)"
        backup_time="$(extract_cron_time "$backup_line")"
        if [[ -n "$backup_time" ]]; then
            add_result OK "CRON" "backup cron present (${backup_time})"
        else
            add_result OK "CRON" "backup cron present"
        fi
    else
        local default_time="${INM_CRON_BACKUP_TIME:-03:24}"
        add_result WARN "CRON" "backup cron missing; run: inm core cron install --jobs=backup --backup-time=${default_time}"
    fi
    if echo "$cron_scope" | grep -qE "notify-heartbeat"; then
        local heartbeat_line heartbeat_time
        heartbeat_line="$(echo "$cron_scope" | grep -E "notify-heartbeat" | head -n1)"
        heartbeat_time="$(extract_cron_time "$heartbeat_line")"
        if [[ -n "$heartbeat_time" ]]; then
            add_result OK "CRON" "heartbeat cron present (${heartbeat_time})"
        else
            add_result OK "CRON" "heartbeat cron present"
        fi
    else
        local hb_default_time="${INM_NOTIFY_HEARTBEAT_TIME:-06:00}"
        local hb_enabled="${INM_NOTIFY_HEARTBEAT_ENABLED:-false}"
        hb_enabled="${hb_enabled,,}"
        if [[ "$hb_enabled" =~ ^(1|true|yes|y|on)$ ]]; then
            add_result WARN "CRON" "heartbeat cron missing; run: inm core cron install --jobs=heartbeat --heartbeat-time=${hb_default_time}"
        else
            add_result INFO "CRON" "heartbeat cron not enabled (set INM_NOTIFY_HEARTBEAT_ENABLED=true)"
        fi
    fi
    fi

    if should_run "SNAPPDF"; then
    # ---- Snappdf presence (only if enabled) ----
    if [ "$fast" != true ] && [ "$skip_snappdf" != true ]; then
        local pdf_gen="${PDF_GENERATOR:-}"
        if [ -z "$pdf_gen" ] && [ -f "${INM_ENV_FILE:-}" ]; then
            pdf_gen=$(grep -E '^PDF_GENERATOR=' "$INM_ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)
        fi
        if [[ "${pdf_gen,,}" != "snappdf" ]]; then
            add_result INFO "SNAPPDF" "PDF_GENERATOR not 'snappdf' (current: ${pdf_gen:-unset}); check skipped"
        else
            local snap_dir="${INM_INSTALLATION_PATH%/}/vendor/beganovich/snappdf"
            local snappdf_cli="${INM_INSTALLATION_PATH%/}/vendor/bin/snappdf"
            if [ ! -d "$snap_dir" ]; then
                add_result WARN "SNAPPDF" "Not present; run do_snappdf/update"
            elif [ -z "${INM_INSTALLATION_PATH:-}" ] || [ ! -f "${INM_INSTALLATION_PATH%/}/vendor/autoload.php" ]; then
                add_result WARN "SNAPPDF" "Vendor/autoload missing; cannot test snappdf"
            else
                if [ ! -x "$snappdf_cli" ]; then
                    add_result WARN "SNAPPDF" "snappdf CLI missing: $snappdf_cli"
                fi
                local chromium_path=""
                if [ -n "${SNAPPDF_EXECUTABLE_PATH:-}" ]; then
                    chromium_path="$SNAPPDF_EXECUTABLE_PATH"
                    if [ ! -x "$chromium_path" ]; then
                        add_result WARN "SNAPPDF" "SNAPPDF_EXECUTABLE_PATH not executable: $chromium_path"
                    else
                        add_result INFO "SNAPPDF" "Chromium path: $chromium_path (SNAPPDF_EXECUTABLE_PATH)"
                    fi
                elif [ -n "${SNAPPDF_CHROMIUM_PATH:-}" ]; then
                    chromium_path="$SNAPPDF_CHROMIUM_PATH"
                    if [ ! -x "$chromium_path" ]; then
                        add_result WARN "SNAPPDF" "SNAPPDF_CHROMIUM_PATH not executable: $chromium_path"
                    else
                        add_result INFO "SNAPPDF" "Chromium path: $chromium_path (SNAPPDF_CHROMIUM_PATH)"
                    fi
                else
                    chromium_path="$(find "$snap_dir/versions" -type f -perm -u+x '(' -name Chromium -o -name chrome -o -name chromium ')' 2>/dev/null | head -n1)"
                    if [ -n "$chromium_path" ]; then
                        add_result INFO "SNAPPDF" "Chromium path: $chromium_path"
                    fi
                fi

                if [[ "${SNAPPDF_SKIP_DOWNLOAD:-}" == "true" || "${SNAPPDF_SKIP_DOWNLOAD:-}" == "1" ]]; then
                    add_result INFO "SNAPPDF" "SNAPPDF_SKIP_DOWNLOAD=true"
                fi

                local probe_dir="${INM_CACHE_LOCAL_DIRECTORY:-/tmp}"
                if [[ -n "$probe_dir" ]]; then
                    mkdir -p "$probe_dir" 2>/dev/null || true
                fi
                if [[ -z "$probe_dir" || ! -w "$probe_dir" ]]; then
                    probe_dir="/tmp"
                fi
                if [[ ! -w "$probe_dir" ]]; then
                    add_result WARN "SNAPPDF" "Probe dir not writable; set INM_CACHE_LOCAL_DIRECTORY to a writable path."
                else
                local tmp_pdf="${probe_dir%/}/snappdf_probe.pdf"
                # Try to render a tiny PDF
                local php_probe php_exec probe_file
                php_exec="${INM_PHP_EXECUTABLE:-php}"
                probe_file="$(mktemp "${probe_dir%/}/snappdf_probe_XXXX.php" 2>/dev/null || true)"
                if [[ -z "$probe_file" ]]; then
                    probe_file="$(mktemp "/tmp/snappdf_probe_XXXX.php" 2>/dev/null || true)"
                fi
                if [[ -z "$probe_file" ]]; then
                    add_result WARN "SNAPPDF" "Failed to create probe file; cannot verify snappdf."
                else
                    cat > "$probe_file" <<PHP
<?php
require '${INM_INSTALLATION_PATH%/}/vendor/autoload.php';
if (class_exists('Beganovich\\Snappdf\\Snappdf')) {
    try {
        \$pdf = new Beganovich\\Snappdf\\Snappdf;
        if (method_exists(\$pdf, 'setHtml')) {
            \$pdf->setHtml('<h1>probe</h1>');
        }
        if (method_exists(\$pdf, 'save')) {
            \$pdf->save('${tmp_pdf}');
            if (is_file('${tmp_pdf}') && filesize('${tmp_pdf}') > 0) {
                echo 'OK';
            } else {
                echo 'ERR:save did not create file';
            }
        } elseif (method_exists(\$pdf, 'generate')) {
            \$out = \$pdf->generate();
            if (!is_string(\$out) || \$out === '') {
                echo 'ERR:generate returned empty';
            } elseif (file_put_contents('${tmp_pdf}', \$out) === false) {
                echo 'ERR:write failed';
            } else {
                echo 'OK';
            }
        } else {
            echo 'ERR:No save/generate method';
        }
    } catch (Throwable \$e) {
        echo 'ERR:' . \$e->getMessage();
    }
} else {
    echo 'ERR:Snappdf class not found';
}
PHP
                    log debug "[SNAPPDF] Probe cmd: $php_exec $probe_file"
                fi
                if [[ -n "$probe_file" ]]; then
                    if [[ "${DEBUG:-false}" == true ]]; then
                        php_probe=$("$php_exec" "$probe_file" 2>&1 || true)
                    else
                        php_probe=$("$php_exec" "$probe_file" 2>/dev/null || true)
                    fi
                    log debug "[SNAPPDF] Probe output: ${php_probe:-<empty>}"
                    rm -f "$probe_file" 2>/dev/null || true
                else
                    php_probe=""
                fi
                if echo "$php_probe" | grep -q "^OK"; then
                    if [ -s "$tmp_pdf" ]; then
                        add_result OK "SNAPPDF" "Render ok (probe at ${tmp_pdf})"
                        rm -f "$tmp_pdf"
                    else
                        add_result WARN "SNAPPDF" "Probe returned OK but output missing (probe dir writable: ${probe_dir}). See https://github.com/beganovich/snappdf (use --debug for details)"
                        if [ -n "$chromium_path" ] && command -v ldd >/dev/null 2>&1; then
                            local missing_libs
                            missing_libs=$(ldd "$chromium_path" 2>/dev/null | awk '/not found/ {print $1}' | xargs)
                            if [ -n "$missing_libs" ]; then
                                add_result WARN "SNAPPDF" "Chromium missing libs: ${missing_libs}"
                            fi
                        fi
                    fi
                elif [[ "$php_probe" == ERR:* ]]; then
                    add_result WARN "SNAPPDF" "Render failed (${php_probe}). See https://github.com/beganovich/snappdf (use --debug for details)"
                    if [ -n "$chromium_path" ] && command -v ldd >/dev/null 2>&1; then
                        local missing_libs
                        missing_libs=$(ldd "$chromium_path" 2>/dev/null | awk '/not found/ {print $1}' | xargs)
                        if [ -n "$missing_libs" ]; then
                            add_result WARN "SNAPPDF" "Chromium missing libs: ${missing_libs}"
                        fi
                    fi
                else
                    add_result WARN "SNAPPDF" "Render failed (no output). See https://github.com/beganovich/snappdf (use --debug for details)"
                    if [ -n "$chromium_path" ] && command -v ldd >/dev/null 2>&1; then
                        local missing_libs
                        missing_libs=$(ldd "$chromium_path" 2>/dev/null | awk '/not found/ {print $1}' | xargs)
                        if [ -n "$missing_libs" ]; then
                            add_result WARN "SNAPPDF" "Chromium missing libs: ${missing_libs}"
                        fi
                    fi
                fi
                fi
            fi
        fi
    fi
    fi

    if should_run "NET"; then
    # ---- GitHub reachability ----
    if [ "$fast" != true ] && [ "$skip_github" != true ]; then
        if curl -Is --connect-timeout 5 https://github.com >/dev/null 2>&1; then
            add_result OK "NET" "GitHub reachable"
        else
            add_result WARN "NET" "GitHub not reachable"
        fi
    fi

    # ---- Network reachability for APP_URL ----
    if [ -n "${APP_URL:-}" ]; then
        local host_only scheme app_url_trim
        app_url_trim="${APP_URL%/}"
        host_only=$(echo "$app_url_trim" | sed -E 's@https?://([^/]+).*@\1@')
        scheme=$(echo "$app_url_trim" | sed -E 's@^(https?)://.*@\1@')
        if [ -n "$host_only" ]; then
            if getent hosts "$host_only" >/dev/null 2>&1 || host "$host_only" >/dev/null 2>&1; then
                add_result INFO "NET" "DNS resolves: $host_only"
            else
                add_result WARN "NET" "DNS failed: $host_only"
            fi
            local curl_ok=false
            if curl -Is --connect-timeout 5 "$app_url_trim" >/dev/null 2>&1; then
                add_result INFO "NET" "APP_URL reachable: $app_url_trim"
                curl_ok=true
            elif [ "$scheme" = "https" ] && curl -Is -k --connect-timeout 5 "$app_url_trim" >/dev/null 2>&1; then
                add_result WARN "NET" "Webserver certificate does not match URL: $app_url_trim"
                curl_ok=true
            fi
            if [ "$curl_ok" != true ]; then
                local http_fallback="${app_url_trim/https:\/\//http://}"
                if curl -Is --connect-timeout 5 "$http_fallback" >/dev/null 2>&1; then
                    add_result WARN "NET" "HTTPS failed; reachable via HTTP: $http_fallback"
                else
                    add_result WARN "NET" "APP_URL not reachable: $app_url_trim"
                fi
            fi
        fi
    fi
    fi

    if should_run "MAIL"; then
    # ---- SMTP reachability ----
    if [ -n "${INM_ENV_FILE:-}" ] && [ -f "$INM_ENV_FILE" ]; then
        local smtp_mailer smtp_host smtp_port
        smtp_mailer=$(read_env_value "$INM_ENV_FILE" "MAIL_MAILER")
        if [ -z "$smtp_mailer" ]; then
            smtp_mailer=$(read_env_value "$INM_ENV_FILE" "MAIL_DRIVER")
        fi
        smtp_host=$(read_env_value "$INM_ENV_FILE" "MAIL_HOST")
        smtp_port=$(read_env_value "$INM_ENV_FILE" "MAIL_PORT")
        if [ -n "$smtp_mailer" ] && [ "$smtp_mailer" != "smtp" ]; then
            add_result INFO "MAIL" "Mail: ${smtp_mailer} currently active (SMTP check skipped)"
        elif [ -n "$smtp_host" ]; then
            smtp_port="${smtp_port:-587}"
            local smtp_out smtp_detail
            if [ "${DEBUG:-false}" = true ]; then
                # shellcheck disable=SC2016
                smtp_out=$(INM_SMTP_HOST="$smtp_host" INM_SMTP_PORT="$smtp_port" php -r '
$host = getenv("INM_SMTP_HOST");
$port = (int) getenv("INM_SMTP_PORT");
$timeout = 3;
$errno = 0;
$errstr = "";
$fp = @fsockopen($host, $port, $errno, $errstr, $timeout);
if ($fp) { fclose($fp); echo "OK"; } else { echo "ERR:" . $errstr; }' 2>&1 || true)
            else
                # shellcheck disable=SC2016
                smtp_out=$(INM_SMTP_HOST="$smtp_host" INM_SMTP_PORT="$smtp_port" php -r '
$host = getenv("INM_SMTP_HOST");
$port = (int) getenv("INM_SMTP_PORT");
$timeout = 3;
$errno = 0;
$errstr = "";
$fp = @fsockopen($host, $port, $errno, $errstr, $timeout);
if ($fp) { fclose($fp); echo "OK"; } else { echo "ERR:" . $errstr; }' 2>/dev/null || true)
            fi
            if echo "$smtp_out" | grep -q "^OK"; then
                add_result OK "MAIL" "SMTP reachable: ${smtp_host}:${smtp_port}"
            else
                if [ "${DEBUG:-false}" = true ] && echo "$smtp_out" | grep -q "^ERR:"; then
                    smtp_detail="SMTP not reachable: ${smtp_host}:${smtp_port} (${smtp_out#ERR:})"
                else
                    smtp_detail="SMTP not reachable: ${smtp_host}:${smtp_port}"
                fi
                add_result WARN "MAIL" "$smtp_detail"
            fi
        else
            add_result INFO "MAIL" "Mail: not configured (MAIL_MAILER/MAIL_HOST unset)"
        fi
    fi
    fi

    if declare -F spinner_stop >/dev/null 2>&1; then
        spinner_stop
    fi

    # Summary table (grouped)
    printf "\n"
    local groups=("SYS" "FS" "APP" "ENVCLI" "ENVAPP" "CLI" "CMD" "WEB" "PHP" "WEBPHP" "EXT" "NET" "MAIL" "DB" "CRON" "SNAPPDF")
    local idx g printed
    local green="${GREEN:-}"
    local yellow="${YELLOW:-}"
    local red="${RED:-}"
    local reset="${RESET:-}"

    # Human-friendly labels
    format_check_label() {
        case "$1" in
            CLI) echo "CLI" ;;
            SYS) echo "System" ;;
            ENVCLI) echo "ENV CLI" ;;
            APP) echo "App" ;;
            ENVAPP) echo "ENV APP" ;;
            CMD) echo "CLI Commands" ;;
            NET) echo "Network" ;;
            MAIL) echo "Mail Route" ;;
            WEB) echo "Web Server" ;;
            PHP) echo "PHP CLI" ;;
            EXT) echo "PHP Extensions" ;;
            WEBPHP) echo "PHP Web" ;;
            FS) echo "Filesystem" ;;
            DB) echo "Database" ;;
            CRON) echo "Cron" ;;
            SNAPPDF) echo "Snappdf" ;;
            *) echo "$1" ;;
        esac
    }

    # Global column widths (stable across groups)
    local max_check=7 max_status=6
    for idx in "${!PF_STATUS[@]}"; do
        local check_label
        check_label="$(format_check_label "${PF_CHECK[$idx]}")"
        local status="${PF_STATUS[$idx]}"
        (( ${#check_label}  > max_check )) && max_check=${#check_label}
        (( ${#status} > max_status )) && max_status=${#status}
    done

    for g in "${groups[@]}"; do
        printed=false
        # Print
        for idx in "${!PF_STATUS[@]}"; do
            if [[ "${PF_CHECK[$idx]}" == "$g" ]]; then
                if [ "$printed" = false ]; then
                    local header
                    header="$(format_check_label "$g")"
                    printf "%b\n" "${BLUE}== $header ==${reset}"
                    printf "%-*s | %-*s | %s\n" "$max_check" "Subject" "$max_status" "Status" "Detail"
                    printf "%s\n" "$(printf '%*s' $((max_check+max_status+12)) '' | tr ' ' '-')"
                    printed=true
                fi
                local raw_status="${PF_STATUS[$idx]}"
                printf -v status_field "%-*s" "$max_status" "$raw_status"
                case "$raw_status" in
                    OK)   status_field="${green}${status_field}${reset}";;
                    WARN) status_field="${yellow}${status_field}${reset}";;
                    ERR)  status_field="${red}${status_field}${reset}";;
                esac
                local row
                local check_label
                check_label="$(format_check_label "${PF_CHECK[$idx]}")"
                printf -v check_field "%-*s" "$max_check" "$check_label"
                row=$(printf "%s | %s | %s" "$check_field" "$status_field" "${PF_DETAIL[$idx]}")
                printf "%b\n" "$row"
            fi
        done
        if [ "$printed" = true ]; then
            printf "\n"
        fi
    done

    log info "[${pf_label}] Completed: OK=$ok WARN=$warn ERR=$err"
    local aggregate_status="OK"
    if [ "$err" -gt 0 ]; then
        aggregate_status="ERR"
    elif [ "$warn" -gt 0 ]; then
        aggregate_status="WARN"
    fi
    log info "[${pf_label}] Aggregate status: ${aggregate_status}"

    if [[ "$notify_heartbeat" == true || "$notify_test" == true ]]; then
        local notify_summary=""
        local include_ok=false
        if [[ "$notify_test" == true ]]; then
            include_ok=true
        fi
        local idx g
        for g in "${groups[@]}"; do
            local printed=false
            for idx in "${!PF_STATUS[@]}"; do
                if [[ "${PF_CHECK[$idx]}" == "$g" ]]; then
                    local status="${PF_STATUS[$idx]}"
                    if [[ "$include_ok" == true || "$status" != "OK" ]]; then
                        if [ "$printed" = false ]; then
                            printf -v notify_summary '%s== %s ==\n' "$notify_summary" "$(format_check_label "$g")"
                            printed=true
                        fi
                        local check_label
                        check_label="$(format_check_label "${PF_CHECK[$idx]}")"
                        printf -v notify_summary '%s%s | %s | %s\n' "$notify_summary" "$check_label" "$status" "${PF_DETAIL[$idx]}"
                    fi
                fi
            done
            if [ "$printed" = true ]; then
                printf -v notify_summary '%s\n' "$notify_summary"
            fi
        done
        notify_summary="${notify_summary%$'\n'}"
        if [[ "$notify_heartbeat" == true ]]; then
            if declare -F notify_emit_heartbeat >/dev/null 2>&1; then
                notify_emit_heartbeat "$aggregate_status" "$ok" "$warn" "$err" "$notify_summary"
            else
                log warn "[${pf_label}] Notification service missing; heartbeat skipped."
            fi
        fi
        if [[ "$notify_test" == true ]]; then
            if declare -F notify_send_test >/dev/null 2>&1; then
                notify_send_test "$aggregate_status" "$ok" "$warn" "$err" "$notify_summary"
            else
                log warn "[${pf_label}] Notification service missing; notify-test skipped."
            fi
        fi
    fi

    if [ "$err" -gt 0 ]; then
        $errexit_set && set -e
        return 1
    fi
    $errexit_set && set -e
    return 0
}

# ---------------------------------------------------------------------
# check_web_php()
# Creates a temporary php info probe in public/ and fetches via APP_URL.
# ---------------------------------------------------------------------
write_phpinfo_probe() {
    local path="$1"
    cat > "$path" <<'PHP'
<?php
function phpinfo_value($html, $label) {
    $label = preg_quote($label, '/');
    if (preg_match('/<tr><td class="e">' . $label . '<\\/td><td class="v">([^<]*)<\\/td><\\/tr>/i', $html, $m)) {
        return html_entity_decode($m[1], ENT_QUOTES);
    }
    if (preg_match('/<tr><td class="e">' . $label . '<\\/td><td class="v">([^<]*)<\\/td><td class="v">([^<]*)<\\/td><\\/tr>/i', $html, $m)) {
        return html_entity_decode($m[1], ENT_QUOTES);
    }
    return '';
}

ob_start();
phpinfo(INFO_GENERAL | INFO_CONFIGURATION);
$html = ob_get_clean();
$html = str_replace("\n", "", $html);

$values = [
    'PHP_VERSION' => phpinfo_value($html, 'PHP Version'),
    'PHP_SAPI' => phpinfo_value($html, 'Server API'),
    'PHP_INI' => phpinfo_value($html, 'Loaded Configuration File'),
    'PHP_INI_SCAN_DIR' => phpinfo_value($html, 'Scan this dir for additional .ini files'),
    'PHP_INI_SCANNED' => phpinfo_value($html, 'Additional .ini files parsed'),
    'USER_INI' => phpinfo_value($html, 'user_ini.filename'),
    'MEMORY_LIMIT' => phpinfo_value($html, 'memory_limit'),
    'MAX_INPUT_VARS' => phpinfo_value($html, 'max_input_vars'),
    'OPCACHE' => phpinfo_value($html, 'opcache.enable'),
    'MAX_EXEC' => phpinfo_value($html, 'max_execution_time'),
    'MAX_INPUT_TIME' => phpinfo_value($html, 'max_input_time'),
    'POST_MAX' => phpinfo_value($html, 'post_max_size'),
    'UPLOAD_MAX' => phpinfo_value($html, 'upload_max_filesize'),
    'REALPATH_CACHE_SIZE' => phpinfo_value($html, 'realpath_cache_size'),
    'DISPLAY_ERRORS' => phpinfo_value($html, 'display_errors'),
    'ERROR_REPORTING' => phpinfo_value($html, 'error_reporting'),
    'OPEN_BASEDIR' => phpinfo_value($html, 'open_basedir'),
    'DISABLE_FUNCTIONS' => phpinfo_value($html, 'disable_functions'),
    'PROC_OPEN' => function_exists('proc_open') ? '1' : '0',
    'EXEC' => function_exists('exec') ? '1' : '0',
    'FPASSTHRU' => function_exists('fpassthru') ? '1' : '0',
];

$values['PHP_VERSION'] = $values['PHP_VERSION'] ?: PHP_VERSION;
$values['PHP_SAPI'] = $values['PHP_SAPI'] ?: php_sapi_name();
$values['PHP_INI'] = $values['PHP_INI'] ?: php_ini_loaded_file();
$values['PHP_INI_SCAN_DIR'] = $values['PHP_INI_SCAN_DIR'] ?: (get_cfg_var('cfg_file_scan_dir') ?: '');
$values['PHP_INI_SCANNED'] = $values['PHP_INI_SCANNED'] ?: php_ini_scanned_files();
$values['USER_INI'] = $values['USER_INI'] ?: (get_cfg_var('user_ini.filename') ?: '');
$values['MEMORY_LIMIT'] = $values['MEMORY_LIMIT'] ?: ini_get('memory_limit');
$values['MAX_INPUT_VARS'] = $values['MAX_INPUT_VARS'] ?: ini_get('max_input_vars');
$values['OPCACHE'] = $values['OPCACHE'] ?: ini_get('opcache.enable');
$values['MAX_EXEC'] = $values['MAX_EXEC'] ?: ini_get('max_execution_time');
$values['MAX_INPUT_TIME'] = $values['MAX_INPUT_TIME'] ?: ini_get('max_input_time');
$values['POST_MAX'] = $values['POST_MAX'] ?: ini_get('post_max_size');
$values['UPLOAD_MAX'] = $values['UPLOAD_MAX'] ?: ini_get('upload_max_filesize');
$values['REALPATH_CACHE_SIZE'] = $values['REALPATH_CACHE_SIZE'] ?: ini_get('realpath_cache_size');
$values['DISPLAY_ERRORS'] = $values['DISPLAY_ERRORS'] ?: ini_get('display_errors');
$values['ERROR_REPORTING'] = $values['ERROR_REPORTING'] ?: ini_get('error_reporting');
$values['OPEN_BASEDIR'] = $values['OPEN_BASEDIR'] ?: ini_get('open_basedir');
$values['DISABLE_FUNCTIONS'] = $values['DISABLE_FUNCTIONS'] ?: ini_get('disable_functions');

foreach ($values as $key => $val) {
    $val = trim(str_replace("\n", " ", (string) $val));
    echo $key . "=" . $val . "\n";
}
PHP
}

shorten_ini_scanned() {
    local scanned="$1"
    local max_items="${2:-6}"
    local count=0
    local shown=0
    local out=""
    local part
    IFS=',' read -r -a parts <<< "$scanned"
    for part in "${parts[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [[ -z "$part" ]] && continue
        ((count++))
        if ((shown < max_items)); then
            out="${out}${out:+, }${part}"
            ((shown++))
        fi
    done
    if ((count == 0)); then
        printf "%s" ""
    elif ((count <= max_items)); then
        printf "%s (total %d)" "$out" "$count"
    else
        printf "%s (+%d more, total %d)" "$out" "$((count - max_items))" "$count"
    fi
}

phpinfo_probe_cli() {
    local tmp_file
    tmp_file="$(mktemp)" || return 1
    write_phpinfo_probe "$tmp_file"
    php "$tmp_file" 2>/dev/null || true
    rm -f "$tmp_file" 2>/dev/null || true
}

php_emit() {
    local add_fn="$1"
    local status="$2"
    local tag="$3"
    local msg="$4"
    "$add_fn" "$status" "$tag" "$msg"
}

php_thresholds() {
    local add_fn="$1"
    local tag="$2"
    local mem="$3"
    local inputvars="$4"
    local opc="$5"
    local max_exec="$6"
    local max_input_time="$7"
    local post_max="$8"
    local upload_max="$9"
    local realpath_cache="${10}"
    local display_errors="${11}"
    local error_reporting="${12}"
    local proc_open="${13}"
    local exec_fn="${14}"
    local fpassthru_fn="${15}"
    local open_basedir="${16}"
    local disable_functions="${17}"

    local mem_mb
    mem_mb="$(mem_to_mb "$mem")"
    if [ "$mem" = "-1" ]; then
        php_emit "$add_fn" OK "$tag" "memory_limit unlimited (-1)"
    elif [ -n "$mem_mb" ] && [ "$mem_mb" -ge 256 ] 2>/dev/null; then
        php_emit "$add_fn" OK "$tag" "memory_limit ${mem:-unset}"
    elif [ -n "$mem_mb" ] && [ "$mem_mb" -ge 128 ] 2>/dev/null; then
        php_emit "$add_fn" WARN "$tag" "memory_limit ${mem:-unset} (consider >=256M)"
    else
        php_emit "$add_fn" ERR "$tag" "memory_limit too low (${mem:-unset})"
    fi

    if [ -n "$inputvars" ] && [ "$inputvars" -ge 5000 ] 2>/dev/null; then
        php_emit "$add_fn" OK "$tag" "max_input_vars $inputvars"
    elif [ -n "$inputvars" ] && [ "$inputvars" -ge 3000 ] 2>/dev/null; then
        php_emit "$add_fn" WARN "$tag" "max_input_vars $inputvars (consider >=5000)"
    else
        php_emit "$add_fn" ERR "$tag" "max_input_vars too low (${inputvars:-unset})"
    fi

    case "$(printf '%s' "$opc" | tr '[:upper:]' '[:lower:]')" in
        1|on|enabled|true) opc="enabled" ;;
    esac
    if [ "$opc" = "enabled" ]; then
        php_emit "$add_fn" INFO "$tag" "OPcache enabled"
    else
        php_emit "$add_fn" INFO "$tag" "OPcache disabled (use OPcache or another cache like Redis/Memcached)"
    fi

    if [[ "$max_exec" == "0" ]]; then
        php_emit "$add_fn" OK "$tag" "max_execution_time unlimited (0)"
    elif [ -n "$max_exec" ] && [ "$max_exec" -ge 180 ] 2>/dev/null; then
        php_emit "$add_fn" OK "$tag" "max_execution_time ${max_exec}"
    elif [ -n "$max_exec" ] && [ "$max_exec" -ge 60 ] 2>/dev/null; then
        php_emit "$add_fn" WARN "$tag" "max_execution_time ${max_exec} (consider >=180 for large imports)"
    else
        php_emit "$add_fn" ERR "$tag" "max_execution_time too low (${max_exec:-unset})"
    fi

    if [[ "$max_input_time" == "-1" ]]; then
        php_emit "$add_fn" OK "$tag" "max_input_time -1 (use max_execution_time)"
    elif [ -n "$max_input_time" ] && [ "$max_input_time" -ge 180 ] 2>/dev/null; then
        php_emit "$add_fn" OK "$tag" "max_input_time ${max_input_time}"
    elif [ -n "$max_input_time" ] && [ "$max_input_time" -ge 60 ] 2>/dev/null; then
        php_emit "$add_fn" WARN "$tag" "max_input_time ${max_input_time} (consider >=180 for large imports)"
    else
        php_emit "$add_fn" ERR "$tag" "max_input_time too low (${max_input_time:-unset})"
    fi

    local post_mb upload_mb
    post_mb="$(mem_to_mb "$post_max")"
    upload_mb="$(mem_to_mb "$upload_max")"
    if [ -n "$post_mb" ] && [ "$post_mb" -ge 128 ] 2>/dev/null; then
        php_emit "$add_fn" OK "$tag" "post_max_size ${post_max}"
    elif [ -n "$post_mb" ] && [ "$post_mb" -ge 50 ] 2>/dev/null; then
        php_emit "$add_fn" WARN "$tag" "post_max_size ${post_max} (consider >=128M for large imports)"
    else
        php_emit "$add_fn" ERR "$tag" "post_max_size too low (${post_max:-unset})"
    fi
    if [ -n "$upload_mb" ] && [ "$upload_mb" -ge 128 ] 2>/dev/null; then
        php_emit "$add_fn" OK "$tag" "upload_max_filesize ${upload_max}"
    elif [ -n "$upload_mb" ] && [ "$upload_mb" -ge 50 ] 2>/dev/null; then
        php_emit "$add_fn" WARN "$tag" "upload_max_filesize ${upload_max} (consider >=128M for large imports)"
    else
        php_emit "$add_fn" ERR "$tag" "upload_max_filesize too low (${upload_max:-unset})"
    fi

    if [ -n "$realpath_cache" ]; then
        php_emit "$add_fn" INFO "$tag" "realpath_cache_size ${realpath_cache}"
    fi

    if [ -n "$display_errors" ]; then
        php_emit "$add_fn" INFO "$tag" "display_errors ${display_errors}"
    fi

    if [ -n "$error_reporting" ]; then
        php_emit "$add_fn" INFO "$tag" "error_reporting ${error_reporting}"
    fi

    if [[ "$proc_open" == "1" ]]; then
        php_emit "$add_fn" OK "$tag" "proc_open available"
    else
        php_emit "$add_fn" ERR "$tag" "proc_open missing"
    fi

    if [[ "$exec_fn" == "1" ]]; then
        php_emit "$add_fn" OK "$tag" "exec available"
    else
        php_emit "$add_fn" ERR "$tag" "exec missing"
    fi

    if [[ "$fpassthru_fn" == "1" ]]; then
        php_emit "$add_fn" OK "$tag" "fpassthru available"
    else
        php_emit "$add_fn" ERR "$tag" "fpassthru missing"
    fi

    if [[ -n "$open_basedir" ]]; then
        php_emit "$add_fn" WARN "$tag" "open_basedir ${open_basedir}"
    else
        php_emit "$add_fn" OK "$tag" "open_basedir empty"
    fi

    if [[ -n "$disable_functions" ]]; then
        php_emit "$add_fn" INFO "$tag" "disable_functions ${disable_functions}"
    else
        php_emit "$add_fn" INFO "$tag" "disable_functions <none>"
    fi
}

check_web_php() {
    local php_cli_version="$1"
    local add_fn="$2"
    local webroot="${INM_INSTALLATION_PATH%/}/public"
    local tmpfile=".inm_php_probe_$RANDOM.php"
    local url=""

    if [ -n "${APP_URL:-}" ]; then
        url="${APP_URL%/}"
    fi

    # Try to infer APP_URL from nginx if still unset
    if [ -z "$url" ] && [ -d /etc/nginx/sites-enabled ]; then
        local cfg
        cfg=$(grep -R "root ${webroot//\//\\/}" -n /etc/nginx/sites-enabled 2>/dev/null | head -n1 | cut -d: -f1)
        if [ -n "$cfg" ]; then
            local host
            host=$(grep -E "server_name" "$cfg" | grep -v default_server | head -n1 | awk '{print $2}' | tr -d ';')
            if [ -n "$host" ]; then
                url="http://${host%/}"
            fi
        fi
    fi

    # If still unset, skip web probe (no reliable target)
    if [ -z "$url" ]; then
        ${add_fn:-log info} INFO "WEBPHP" "APP_URL not set; skipping web probe"
        return 0
    fi

    # Ensure webroot exists and is writable before probing
    local webroot_created=false
    local can_enforce="${INM_PREFLIGHT_CAN_ENFORCE:-false}"
    if [[ ! -d "$webroot" ]]; then
        if mkdir -p "$webroot" 2>/dev/null; then
            webroot_created=true
            if declare -F preflight_track_created_dir >/dev/null 2>&1; then
                preflight_track_created_dir "$webroot"
            fi
        fi
    fi
    if [[ "$webroot_created" == true && "$can_enforce" == true ]]; then
        if declare -F enforce_ownership >/dev/null 2>&1; then
            enforce_ownership "$webroot"
        fi
        if [[ -n "${INM_DIR_MODE:-}" ]] && declare -F enforce_dir_permissions >/dev/null 2>&1; then
            enforce_dir_permissions "$INM_DIR_MODE" "$webroot"
        fi
    fi
    if [[ ! -d "$webroot" ]]; then
        ${add_fn:-log warn} WARN "WEBPHP" "Webroot missing and not created: $webroot"
        return 1
    fi
    if ! touch "$webroot/.inm_probe_touch" 2>/dev/null; then
        ${add_fn:-log warn} WARN "WEBPHP" "Cannot write probe to webroot: $webroot (user: $(whoami)). Hint: chown -R ${enforced_owner:-www-data:www-data} \"$webroot\" or run with --override_enforced_user=true to adjust perms."
        return 1
    else
        rm -f "$webroot/.inm_probe_touch" 2>/dev/null || true
    fi

    write_phpinfo_probe "$webroot/$tmpfile"

    local web_php_out=""
    if command -v curl >/dev/null 2>&1; then
        web_php_out=$(curl -s "${url%/}/$tmpfile" 2>/dev/null)
        # If https fails, try -k; if still empty and was https, try http fallback.
        if [ -z "$web_php_out" ] && echo "$url" | grep -q '^https://'; then
            web_php_out=$(curl -s -k "${url%/}/$tmpfile" 2>/dev/null)
            if [ -z "$web_php_out" ]; then
                local http_fallback="${url/https:\/\//http://}"
                web_php_out=$(curl -s "${http_fallback%/}/$tmpfile" 2>/dev/null)
            fi
        fi
    elif command -v wget >/dev/null 2>&1; then
        web_php_out=$(wget -qO- "${url%/}/$tmpfile" 2>/dev/null)
    fi

    rm -f "$webroot/$tmpfile"

    if [ -z "$web_php_out" ]; then
        ${add_fn:-log warn} WARN "WEBPHP" "Could not retrieve via ${url%/}/$tmpfile"
        return 1
    fi
    if ! echo "$web_php_out" | grep -q '^PHP_VERSION='; then
        ${add_fn:-log warn} WARN "WEBPHP" "Probe did not return PHP details via ${url%/}/$tmpfile"
        return 1
    fi

    local web_php_ver web_php_ini web_ini_scan_dir web_ini_scanned web_php_sapi web_user_ini web_mem web_opc web_input web_max_exec web_max_input_time web_post_max web_upload_max web_realpath_cache web_display_errors web_error_reporting
    local web_proc_open web_exec web_fpassthru web_open_basedir web_disable_functions
    while IFS='=' read -r key val; do
        case "$key" in
            PHP_VERSION) web_php_ver="$val" ;;
            PHP_INI) web_php_ini="$val" ;;
            PHP_INI_SCAN_DIR) web_ini_scan_dir="$val" ;;
            PHP_INI_SCANNED) web_ini_scanned="$val" ;;
            PHP_SAPI) web_php_sapi="$val" ;;
            USER_INI) web_user_ini="$val" ;;
            MEMORY_LIMIT) web_mem="$val" ;;
            OPCACHE) web_opc="$val" ;;
            MAX_INPUT_VARS) web_input="$val" ;;
            MAX_EXEC) web_max_exec="$val" ;;
            MAX_INPUT_TIME) web_max_input_time="$val" ;;
            POST_MAX) web_post_max="$val" ;;
            UPLOAD_MAX) web_upload_max="$val" ;;
            REALPATH_CACHE_SIZE) web_realpath_cache="$val" ;;
            DISPLAY_ERRORS) web_display_errors="$val" ;;
            ERROR_REPORTING) web_error_reporting="$val" ;;
            PROC_OPEN) web_proc_open="$val" ;;
            EXEC) web_exec="$val" ;;
            FPASSTHRU) web_fpassthru="$val" ;;
            OPEN_BASEDIR) web_open_basedir="$val" ;;
            DISABLE_FUNCTIONS) web_disable_functions="$val" ;;
        esac
    done <<< "$web_php_out"

    local web_user_ini_detail="${web_user_ini:-<none>}"
    if [ -n "$web_user_ini" ]; then
        if [ -f "${webroot%/}/$web_user_ini" ]; then
            web_user_ini_detail="${web_user_ini} (public: present)"
        else
            web_user_ini_detail="${web_user_ini} (public: missing)"
        fi
    fi

    ${add_fn:-log info} INFO "WEBPHP" "Version $web_php_ver (CLI ${php_cli_version:-unknown})"
    if [ -n "$web_php_ver" ]; then
        if printf '%s\n' "$web_php_ver" "8.1.0" | sort -V | head -n1 | grep -qx "8.1.0"; then
            ${add_fn:-log info} INFO "WEBPHP" ">= 8.1"
        else
            ${add_fn:-log warn} WARN "WEBPHP" "Needs >= 8.1"
        fi
    fi
    [[ -n "$web_php_sapi" ]] && ${add_fn:-log info} INFO "WEBPHP" "SAPI $web_php_sapi"
    ${add_fn:-log info} INFO "WEBPHP" "php.ini $web_php_ini"
    [[ -n "$web_ini_scan_dir" ]] && ${add_fn:-log info} INFO "WEBPHP" "ini scan dir ${web_ini_scan_dir}"
    if [[ -n "$web_ini_scanned" ]]; then
        local web_ini_short
        web_ini_short="$(shorten_ini_scanned "$web_ini_scanned")"
        ${add_fn:-log info} INFO "WEBPHP" "ini scanned ${web_ini_short}"
    fi
    ${add_fn:-log info} INFO "WEBPHP" ".user.ini $web_user_ini_detail"
    if [[ "$web_user_ini_detail" == "<none>" || "$web_user_ini_detail" == *"(public: missing)"* ]]; then
        ${add_fn:-log info} INFO "WEBPHP" "Tip: write .user.ini with 'inm env user-ini apply'"
    fi

    php_thresholds "${add_fn:-add_result}" "WEBPHP" "$web_mem" "$web_input" "$web_opc" "$web_max_exec" "$web_max_input_time" "$web_post_max" "$web_upload_max" "$web_realpath_cache" "$web_display_errors" "$web_error_reporting" "$web_proc_open" "$web_exec" "$web_fpassthru" "$web_open_basedir" "$web_disable_functions"

    if [ -n "$php_cli_version" ] && [ -n "$web_php_ver" ] && [ "$php_cli_version" != "$web_php_ver" ]; then
        ${add_fn:-log warn} WARN "WEBPHP" "CLI $php_cli_version differs from Web $web_php_ver"
    fi

    return 0
}
