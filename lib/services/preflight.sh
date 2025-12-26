#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_PREFLIGHT_LOADED:-} ]] && return
__SERVICE_PREFLIGHT_LOADED=1

# ---------------------------------------------------------------------
# run_preflight()
# Performs environment checks for inmanage/Invoice Ninja.
# Flags via NAMED_ARGS:
#   --checks=TAG1,TAG2  Only run selected check groups (e.g., CLI,SYS,FS,DB,WEB,PHP,EXT,NET,MAIL,APP,CRON,SNAPPDF)
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

    # Optional check filter (CSV of tags, e.g., CLI,SYS,FS,DB,WEB,PHP,EXT,NET,MAIL,APP,CRON,SNAPPDF)
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
        [fix_permissions]=1
        [debug]=1
        [dry_run]=1
        [force]=1
        [override_enforced_user]=1
        [user]=1
        [no_cli_clear]=1
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
        log info "[${pf_label}] Allowed flags: --checks=TAG1,TAG2 --check=TAG1,TAG2 --fix-permissions --debug --dry-run --override-enforced-user --no-cli-clear"
        $errexit_set && set -e
        return 1
    fi

    local checks_filter="${NAMED_ARGS[checks]:-${NAMED_ARGS[check]:-${ARGS[checks]:-${ARGS[check]:-}}}}"
    declare -A PF_ALLOW=()
    if [[ -n "$checks_filter" ]]; then
        local -a unknown_checks=()
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
        if [[ ${#unknown_checks[@]} -gt 0 ]]; then
            log err "[${pf_label}] Unknown check tags: ${unknown_checks[*]}"
            log info "[${pf_label}] Valid tags: CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,MAIL,DB,APP,CRON,SNAPPDF"
            $errexit_set && set -e
            return 1
        fi
        if [[ ${#PF_ALLOW[@]} -eq 0 ]]; then
            log err "[${pf_label}] No valid check tags in --checks=$checks_filter"
            log info "[${pf_label}] Valid tags: CLI,SYS,FS,ENVCLI,ENVAPP,CMD,WEB,PHP,EXT,WEBPHP,NET,MAIL,DB,APP,CRON,SNAPPDF"
            $errexit_set && set -e
            return 1
        fi
        log debug "[${pf_label}] Checks filter active: $checks_filter"
    fi

    should_run() {
        local tag="$1"
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

    # prefer globally parsed NAMED_ARGS to survive re-exec user switches
    local fix_permissions="${NAMED_ARGS[fix_permissions]:-${NAMED_ARGS[fix-permissions]:-${ARGS[fix_permissions]:-${ARGS[fix-permissions]:-false}}}}"

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
    local cli_root cli_branch cli_commit cli_dirty="" cli_source="snapshot"
    cli_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    add_result INFO "CLI" "CLI: $cli_root"
    if command -v git >/dev/null 2>&1 && [ -d "$cli_root/.git" ]; then
        cli_branch="$(git -C "$cli_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        cli_commit="$(git -C "$cli_root" rev-parse --short HEAD 2>/dev/null || true)"
        git -C "$cli_root" status --porcelain >/dev/null 2>&1 && \
            git -C "$cli_root" status --porcelain | grep -q . && cli_dirty="*"
        cli_branch="${cli_branch:-unknown}"
        cli_commit="${cli_commit:-unknown}"
        add_result INFO "CLI" "Source: git checkout (branch=${cli_branch} commit=${cli_commit}${cli_dirty})"
        local cli_commit_date
        cli_commit_date="$(git -C "$cli_root" log -1 --format=%cd --date=iso 2>/dev/null || true)"
        [[ -n "$cli_commit_date" ]] && add_result INFO "CLI" "Last commit date: $cli_commit_date"
        cli_source="git"
    else
        add_result WARN "CLI" "Source: no git metadata (tarball/snapshot install)"
    fi
    # Optional VERSION file in repo root
    if [ -f "$cli_root/VERSION" ]; then
        local cli_version
        cli_version=$(<"$cli_root/VERSION")
        add_result INFO "CLI" "Version file: ${cli_version}"
    fi
    # Newest file mtime (best-effort)
    local inmanage_mtime="" inmanage_mtime_short="" inmanage_rel="inmanage.sh"
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
            [[ "$latest_file" == "$cli_root/"* ]] && rel_latest="${latest_file#$cli_root/}"
            local latest_short="$(echo "$latest_human" | cut -d. -f1)"
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
    fi
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os="${PRETTY_NAME:-$NAME $VERSION_ID}"
    fi
    add_result INFO "SYS" "Host: ${host:-unknown} | OS: ${os:-unknown}"
    add_result INFO "SYS" "Kernel: ${kernel:-?} | Arch: ${arch:-?} | CPU cores: ${cpu:-?} | RAM: ${memtotal:-unknown}"
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
    if pgrep -x apache2 >/dev/null 2>&1 || pgrep -x apache24 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1; then
        local av
        av=$(apache2 -v 2>/dev/null | awk -F: '/Server version/{print $2}' | xargs)
        [ -z "$av" ] && av=$(httpd -v 2>/dev/null | awk -F: '/Server version/{print $2}' | xargs)
        add_result INFO "WEB" "Apache${av:+ $av}"
        web_is_apache=true
    elif pgrep -x nginx >/dev/null 2>&1; then
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
                add_result WARN "APP" "Config found (${app_cfg_hint}) but app tree is missing/incomplete. Fix: move existing app to ${app_dir} or run 'inmanage core install --provision' (recommended). For guidance, run 'inmanage core install --help'."
            fi
        else
            add_result OK "APP" "App structure looks complete at ${app_dir}"
            if [[ ${#app_warn[@]} -gt 0 ]]; then
                add_result WARN "APP" "Non-critical items missing: ${app_warn[*]}"
            fi
        fi

        if [ -n "${ENFORCED_USER:-}" ]; then
            check_owner_and_fix() {
                local p="$1"
                [ ! -e "$p" ] && return
                local owner
                owner=$(stat -c '%U' "$p" 2>/dev/null || stat -f '%Su' "$p" 2>/dev/null || echo "")
                if [ -n "$owner" ] && [ "$owner" != "$ENFORCED_USER" ]; then
                    if [ "$fix_permissions" = true ]; then
                        add_result WARN "PERM" "Fixing ownership for $p (was $owner -> $ENFORCED_USER)"
                        enforce_ownership "$p"
                    else
                        add_result WARN "PERM" "Ownership mismatch at $p (owner=$owner, expected=$ENFORCED_USER). Use --fix-permissions to repair."
                    fi
                else
                    add_result OK "PERM" "$p owned by ${owner:-unknown}"
                fi
            }
            check_owner_and_fix "${INM_INSTALLATION_PATH%/}"
            check_owner_and_fix "${INM_INSTALLATION_PATH%/}/storage"
            check_owner_and_fix "${INM_INSTALLATION_PATH%/}/public"
        fi
    else
        add_result WARN "APP" "App directory missing or unset: ${INM_INSTALLATION_PATH:-<unset>}"
        if [ -n "$app_cfg_hint" ]; then
            add_result WARN "APP" "Config found (${app_cfg_hint}) but app directory is missing. Fix: move existing app to ${INM_INSTALLATION_PATH%/} or run 'inmanage core install --provision' (recommended). For guidance, run 'inmanage core install --help'."
        fi
    fi
    fi

    if should_run "PHP" || should_run "EXT" || should_run "WEBPHP"; then
    # ---- PHP version / ini ----
    phpv=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
    if [ -z "$phpv" ]; then
        if should_run "PHP"; then
            add_result ERR "PHP" "php CLI not available"
        fi
        if should_run "EXT"; then
            add_result ERR "EXT" "php CLI not available"
        fi
    else
        if should_run "PHP"; then
            add_result OK "PHP" "CLI $phpv"
            local cli_ini
            cli_ini=$(php -r 'echo php_ini_loaded_file();' 2>/dev/null)
            add_result INFO "PHP" "CLI ini: ${cli_ini:-<none>}"
            if printf '%s\n' "$phpv" "8.1.0" | sort -V | head -n1 | grep -qx "8.1.0"; then
                add_result OK "PHP" ">= 8.1"
            else
                add_result ERR "PHP" "Needs >= 8.1"
            fi
            local mem mem_mb
            mem=$(php -r "echo ini_get('memory_limit');" 2>/dev/null)
            mem_mb="$(mem_to_mb "$mem")"
            if [ "$mem" = "-1" ]; then
                add_result OK "PHP" "memory_limit unlimited (-1)"
            elif [ -n "$mem_mb" ] && [ "$mem_mb" -ge 256 ] 2>/dev/null; then
                add_result OK "PHP" "memory_limit ${mem:-unset}"
            else
                add_result WARN "PHP" "memory_limit too low (${mem:-unset})"
            fi
            local inputvars
            inputvars=$(php -r "echo ini_get('max_input_vars');" 2>/dev/null)
            if [ -n "$inputvars" ] && [ "$inputvars" -ge 2000 ] 2>/dev/null; then
                add_result OK "PHP" "max_input_vars $inputvars"
            else
                add_result WARN "PHP" "max_input_vars <2000 (${inputvars:-unset})"
            fi
            local opc
            opc=$(php -r "echo (extension_loaded('Zend OPcache') && ini_get('opcache.enable')) ? 'enabled' : 'disabled';" 2>/dev/null)
            if [ "$opc" = "enabled" ]; then
                add_result OK "PHP" "OPcache enabled"
            else
                add_result WARN "PHP" "OPcache disabled"
            fi
        fi

        if should_run "EXT"; then
            # Extensions
            local exts=(pdo_mysql openssl tokenizer xml gd mbstring bcmath curl zip fileinfo intl)
            for ext in "${exts[@]}"; do
                if php -m | grep -qi "^$ext$"; then
                    add_result OK "EXT" "$ext"
                else
                    add_result ERR "EXT" "$ext missing"
                fi
            done
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
        local diskline
        diskline=$(df -hP "$INM_BASE_DIRECTORY" | awk 'NR==2{print "avail:"$4" used:"$3" mount:"$6}')
        add_result INFO "FS" "$diskline (Disk @base)"
    fi
    # Base, app, backup directories
    local fs_items=(
        "$INM_BASE_DIRECTORY|Base dir"
        "$INM_INSTALLATION_PATH|App dir"
        "$INM_BACKUP_DIRECTORY|Backup dir"
    )
    for entry in "${fs_items[@]}"; do
        local dir label
        dir="${entry%%|*}"
        label="${entry#*|}"
        [ -z "$dir" ] && continue
        mkdir -p "$dir" 2>/dev/null
        local sz=""
        if [ -d "$dir" ] && command -v du >/dev/null 2>&1; then
            sz=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        fi
        if touch "$dir/.inm_perm_test" 2>/dev/null; then
            rm -f "$dir/.inm_perm_test"
            local detail="Writable: $dir ($label)"
            [[ -n "$sz" ]] && detail+=" (Size: $sz)"
            add_result OK "FS" "$detail"
        else
            local hint="$label not writable: $dir"
            if [ -n "${ENFORCED_USER:-}" ]; then
                hint+=" (hint: chown -R ${ENFORCED_USER}:${ENFORCED_USER} \"$dir\" or run 'inmanage core health --fix-permissions')"
            fi
            add_result ERR "FS" "$hint"
        fi
    done

    # Cache directories first
    local cache_global_state="unset"
    local cache_local_state="unset"
    local cache_global_detail=""
    local cache_local_detail=""

    if [ -n "${INM_CACHE_GLOBAL_DIRECTORY:-}" ]; then
        local gc_path gc_parent
        gc_path="$(expand_path_vars "$INM_CACHE_GLOBAL_DIRECTORY")"
        gc_parent="$(dirname "$gc_path")"
        mkdir -p "$gc_parent" 2>/dev/null || true
        if mkdir -p "$gc_path" 2>/dev/null && touch "$gc_path/.inm_perm_test" 2>/dev/null; then
            rm -f "$gc_path/.inm_perm_test"
            cache_global_state="ok"
            cache_global_detail="Writable: $gc_path (Cache global)"
        else
            cache_global_state="fail"
            cache_global_detail="Not writable: $gc_path (Cache global)"
            if [ -n "${ENFORCED_USER:-}" ]; then
                cache_global_detail+=" (hint: chown -R ${ENFORCED_USER}:${ENFORCED_USER} \"$gc_path\" or use --override_enforced_user=true to adjust perms)"
            fi
            cache_global_detail+=" or set INM_CACHE_GLOBAL_DIRECTORY to an accessible path."
        fi
    fi

    if [ -n "${INM_CACHE_LOCAL_DIRECTORY:-}" ]; then
        local lc_path
        lc_path="$(expand_path_vars "$INM_CACHE_LOCAL_DIRECTORY")"
        mkdir -p "$lc_path" 2>/dev/null
        if touch "$lc_path/.inm_perm_test" 2>/dev/null; then
            rm -f "$lc_path/.inm_perm_test"
            cache_local_state="ok"
            cache_local_detail="Writable: $lc_path (Cache local)"
        else
            cache_local_state="fail"
            cache_local_detail="Not writable: $lc_path (Cache local)"
            if [ -n "${ENFORCED_USER:-}" ]; then
                cache_local_detail+=" (hint: chown -R ${ENFORCED_USER}:${ENFORCED_USER} \"$lc_path\" or use --override_enforced_user=true to adjust perms)"
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
    elif [ "$cache_global_state" = "fail" ]; then
        if [ "$cache_any_ok" = true ]; then
            add_result INFO "FS" "${cache_global_detail} (local cache writable; consider fixing global cache for shared use)"
        else
            add_result ERR "FS" "${cache_global_detail} (no writable cache directories)"
        fi
    fi

    if [ "$cache_local_state" = "ok" ]; then
        add_result OK "FS" "$cache_local_detail"
    elif [ "$cache_local_state" = "fail" ]; then
        if [ "$cache_any_ok" = true ]; then
            add_result INFO "FS" "${cache_local_detail} (global cache writable; consider fixing local cache for speed)"
        else
            add_result ERR "FS" "${cache_local_detail} (no writable cache directories)"
        fi
    fi
    fi

    # ---- ENV (CLI / APP) ----
    read_env_value() {
        local file="$1" key="$2"
        grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' ' || true
    }

    if should_run "ENVCLI"; then
        if [ -n "${INM_SELF_ENV_FILE:-}" ] && [ -f "$INM_SELF_ENV_FILE" ]; then
            local cli_keys=(INM_ENFORCED_USER INM_BASE_DIRECTORY INM_INSTALLATION_DIRECTORY INM_BACKUP_DIRECTORY INM_CACHE_GLOBAL_DIRECTORY INM_CACHE_LOCAL_DIRECTORY)
            for k in "${cli_keys[@]}"; do
                local v="${!k}"
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
        set -a
        . "$INM_ENV_FILE" 2>/dev/null || true
        set +a
        add_result INFO "DB" "Loaded DB vars from ${INM_ENV_FILE}"
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
    if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || pgrep -x systemd >/dev/null 2>&1; then
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
    fi
    if [[ -r "$cron_file" ]]; then
        cron_lines+=$'\n'"$(cat "$cron_file")"
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
        add_result WARN "CRON" "artisan schedule missing; run: inmanage core cron install --jobs=scheduler"
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
    if echo "$cron_scope" | grep -q "inmanage core backup"; then
        local backup_line backup_time
        backup_line="$(echo "$cron_scope" | grep -E "inmanage core backup" | head -n1)"
        backup_time="$(extract_cron_time "$backup_line")"
        if [[ -n "$backup_time" ]]; then
            add_result OK "CRON" "backup cron present (${backup_time})"
        else
            add_result OK "CRON" "backup cron present"
        fi
    else
        local default_time="${INM_CRON_BACKUP_TIME:-03:24}"
        add_result WARN "CRON" "backup cron missing; run: inmanage core cron install --jobs=backup --backup-time=${default_time}"
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
                smtp_out=$(INM_SMTP_HOST="$smtp_host" INM_SMTP_PORT="$smtp_port" php -r '
$host = getenv("INM_SMTP_HOST");
$port = (int) getenv("INM_SMTP_PORT");
$timeout = 3;
$errno = 0;
$errstr = "";
$fp = @fsockopen($host, $port, $errno, $errstr, $timeout);
if ($fp) { fclose($fp); echo "OK"; } else { echo "ERR:" . $errstr; }' 2>&1 || true)
            else
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
    log info "[${pf_label}] Aggregate status: $([ "$err" -gt 0 ] && echo ERR || { [ "$warn" -gt 0 ] && echo WARN || echo OK; })"

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
    mkdir -p "$webroot" 2>/dev/null || true
    if ! touch "$webroot/.inm_probe_touch" 2>/dev/null; then
        ${add_fn:-log warn} WARN "WEBPHP" "Cannot write probe to webroot: $webroot (user: $(whoami)). Hint: chown -R ${ENFORCED_USER:-www-data}:${ENFORCED_USER:-www-data} \"$webroot\" or run with --override_enforced_user=true to adjust perms."
        return 1
    else
        rm -f "$webroot/.inm_probe_touch" 2>/dev/null || true
    fi

    cat > "$webroot/$tmpfile" <<'PHP'
<?php
echo "PHP_VERSION=" . PHP_VERSION . "\n";
echo "PHP_INI=" . php_ini_loaded_file() . "\n";
echo "USER_INI=" . get_cfg_var('user_ini.filename') . "\n";
echo "MEMORY_LIMIT=" . ini_get('memory_limit') . "\n";
echo "OPCACHE=" . ((extension_loaded('Zend OPcache') && ini_get('opcache.enable')) ? 'enabled' : 'disabled') . "\n";
echo "INPUT_VARS=" . ini_get('max_input_vars') . "\n";
echo "MAX_EXEC=" . ini_get('max_execution_time') . "\n";
echo "POST_MAX=" . ini_get('post_max_size') . "\n";
echo "UPLOAD_MAX=" . ini_get('upload_max_filesize') . "\n";
PHP

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

    local web_php_ver web_php_ini web_user_ini web_mem web_opc web_input web_max_exec web_post_max web_upload_max
    web_php_ver=$(echo "$web_php_out" | grep '^PHP_VERSION=' | cut -d= -f2)
    web_php_ini=$(echo "$web_php_out" | grep '^PHP_INI=' | cut -d= -f2)
    web_user_ini=$(echo "$web_php_out" | grep '^USER_INI=' | cut -d= -f2)
    web_mem=$(echo "$web_php_out" | grep '^MEMORY_LIMIT=' | cut -d= -f2)
    web_opc=$(echo "$web_php_out" | grep '^OPCACHE=' | cut -d= -f2)
    web_input=$(echo "$web_php_out" | grep '^INPUT_VARS=' | cut -d= -f2)
    web_max_exec=$(echo "$web_php_out" | grep '^MAX_EXEC=' | cut -d= -f2)
    web_post_max=$(echo "$web_php_out" | grep '^POST_MAX=' | cut -d= -f2)
    web_upload_max=$(echo "$web_php_out" | grep '^UPLOAD_MAX=' | cut -d= -f2)

    local web_user_ini_detail="${web_user_ini:-<none>}"
    if [ -n "$web_user_ini" ]; then
        if [ -f "${webroot%/}/$web_user_ini" ]; then
            web_user_ini_detail="${web_user_ini} (public: present)"
        else
            web_user_ini_detail="${web_user_ini} (public: missing)"
        fi
    fi

    ${add_fn:-log info} INFO "WEBPHP" "Version $web_php_ver (CLI ${php_cli_version:-unknown})"
    ${add_fn:-log info} INFO "WEBPHP" "php.ini $web_php_ini"
    ${add_fn:-log info} INFO "WEBPHP" ".user.ini $web_user_ini_detail"

    # Evaluate memory_limit / input_vars similar to CLI thresholds
    local web_mem_mb=""
    web_mem_mb="$(mem_to_mb "$web_mem")"
    if [ "$web_mem" = "-1" ]; then
        ${add_fn:-log info} INFO "WEBPHP" "memory_limit $web_mem"
    elif [ -n "$web_mem_mb" ] && [ "$web_mem_mb" -ge 256 ] 2>/dev/null; then
        ${add_fn:-log info} INFO "WEBPHP" "memory_limit $web_mem"
    else
        ${add_fn:-log warn} WARN "WEBPHP" "memory_limit too low (${web_mem:-unset})"
    fi

    if [ -n "$web_input" ] && [ "$web_input" -ge 2000 ] 2>/dev/null; then
        ${add_fn:-log info} INFO "WEBPHP" "max_input_vars $web_input"
    else
        ${add_fn:-log warn} WARN "WEBPHP" "max_input_vars <2000 (${web_input:-unset})"
    fi

    if [ "$web_opc" = "enabled" ]; then
        ${add_fn:-log info} INFO "WEBPHP" "OPcache enabled"
    else
        ${add_fn:-log warn} WARN "WEBPHP" "OPcache disabled"
    fi

    # Additional useful limits
    [[ -n "$web_max_exec" ]] && ${add_fn:-log info} INFO "WEBPHP" "max_execution_time ${web_max_exec}"
    [[ -n "$web_post_max" ]] && ${add_fn:-log info} INFO "WEBPHP" "post_max_size ${web_post_max}"
    [[ -n "$web_upload_max" ]] && ${add_fn:-log info} INFO "WEBPHP" "upload_max_filesize ${web_upload_max}"

    if [ -n "$php_cli_version" ] && [ -n "$web_php_ver" ] && [ "$php_cli_version" != "$web_php_ver" ]; then
        ${add_fn:-log warn} WARN "WEBPHP" "CLI $php_cli_version differs from Web $web_php_ver"
    fi

    return 0
}
