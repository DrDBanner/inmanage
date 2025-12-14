#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_PREFLIGHT_LOADED:-} ]] && return
__SERVICE_PREFLIGHT_LOADED=1

# ---------------------------------------------------------------------
# run_preflight()
# Performs environment checks for inmanage/Invoice Ninja.
# Flags via NAMED_ARGS:
#   --fast=true         Skip network/snappdf checks
#   --skip-db=true      Skip DB reachability test
#   --skip-github=true  Skip GitHub reachability
#   --skip-snappdf=true Skip Snappdf presence check
#   --skip-web-php=true Skip web PHP check via APP_URL/public
# ---------------------------------------------------------------------
run_preflight() {
    local errexit_set=false
    if [[ $- == *e* ]]; then
        errexit_set=true
        set +e
    fi
    local -A ARGS=()
    parse_named_args ARGS "$@"

    # Results collector
    local -a PF_STATUS=()
    local -a PF_CHECK=()
    local -a PF_DETAIL=()
    add_result() {
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
    local fast="${NAMED_ARGS[fast]:-${ARGS[fast]:-false}}"
    local skip_db="${NAMED_ARGS[skip_db]:-${ARGS[skip_db]:-false}}"
    local skip_github="${NAMED_ARGS[skip_github]:-${ARGS[skip_github]:-false}}"
    local skip_snappdf="${NAMED_ARGS[skip_snappdf]:-${ARGS[skip_snappdf]:-false}}"
    local skip_web_php="${NAMED_ARGS[skip_web_php]:-${ARGS[skip_web_php]:-false}}"
    log debug "[PREFLIGHT] Flags resolved: fast=$fast skip_db=$skip_db skip_github=$skip_github skip_snappdf=$skip_snappdf skip_web_php=$skip_web_php"

    local ok=0 warn=0 err=0
    log info "[PREFLIGHT] Starting system checks (fast=$fast)"

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

    # ---- System details ----
    local host os kernel arch cpu
    host="$(hostname 2>/dev/null || true)"
    kernel="$(uname -r 2>/dev/null || true)"
    arch="$(uname -m 2>/dev/null || true)"
    cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || true)"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os="${PRETTY_NAME:-$NAME $VERSION_ID}"
    fi
    add_result INFO "SYS" "Host: ${host:-unknown} | OS: ${os:-unknown}"
    add_result INFO "SYS" "Kernel: ${kernel:-?} | Arch: ${arch:-?} | CPU cores: ${cpu:-?}"
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
    # Disk info for base dir
    if [ -n "${INM_BASE_DIRECTORY:-}" ] && df -h "$INM_BASE_DIRECTORY" >/dev/null 2>&1; then
        local diskline
        diskline=$(df -h "$INM_BASE_DIRECTORY" | awk 'NR==2{print $1" used:"$3"/"$2" avail:"$4" mount:"$6}')
        add_result INFO "FS" "Disk @base: $diskline"
    fi

    # Hydrate APP_URL from app .env if missing
    if [ -z "${APP_URL:-}" ] && [ -f "${INM_ENV_FILE:-}" ]; then
        local app_url
        app_url=$(grep -E '^APP_URL=' "$INM_ENV_FILE" 2>/dev/null | head -n1 | sed -E 's/^APP_URL=//' | tr -d '"'\'' ')
        if [ -n "$app_url" ]; then
            APP_URL="$app_url"
            add_result INFO "WEBPHP" "APP_URL from app env: ${APP_URL%/}"
        fi
    fi

    # ---- Webserver detection ----
    if pgrep -x apache2 >/dev/null 2>&1 || pgrep -x apache24 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1; then
        local av
        av=$(apache2 -v 2>/dev/null | awk -F: '/Server version/{print $2}' | xargs)
        [ -z "$av" ] && av=$(httpd -v 2>/dev/null | awk -F: '/Server version/{print $2}' | xargs)
        add_result INFO "WEB" "Apache${av:+ $av}"
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
    # Ports 80/443 listening (best-effort)
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ":80 " && add_result INFO "WEB" "Port 80 open"
        ss -lnt 2>/dev/null | grep -q ":443 " && add_result INFO "WEB" "Port 443 open"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -q ":80 " && add_result INFO "WEB" "Port 80 open"
        netstat -lnt 2>/dev/null | grep -q ":443 " && add_result INFO "WEB" "Port 443 open"
    fi

    # ---- Command availability ----
    local req_cmds=(php mysql mysqldump git curl tar rsync zip unzip composer jq awk sed find xargs touch tee)
    for cmd in "${req_cmds[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            add_result OK "CMD" "$cmd"
        else
            add_result ERR "CMD" "$cmd missing"
        fi
    done

    # ---- PHP version / ini ----
    local phpv
    phpv=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
    if [ -z "$phpv" ]; then
        add_result ERR "PHP" "php CLI not available"
    else
        add_result OK "PHP" "CLI $phpv"
        local cli_ini
        cli_ini=$(php -r 'echo php_ini_loaded_file();' 2>/dev/null)
        add_result INFO "PHP" "CLI ini: ${cli_ini:-<none>}"
        if printf '%s\n' "$phpv" "8.1.0" | sort -V | head -n1 | grep -qx "8.1.0"; then
            add_result OK "PHP" ">= 8.1"
        else
            add_result ERR "PHP" "Needs >= 8.1"
        fi
        local mem mem_int
        mem=$(php -r "echo ini_get('memory_limit');" 2>/dev/null)
        mem_int=$(php -r "echo (int)ini_get('memory_limit');" 2>/dev/null)
        if [ "${mem_int:-0}" -lt 0 ]; then
            add_result OK "PHP" "memory_limit unlimited (-1)"
        elif [ "${mem_int:-0}" -ge 256 ]; then
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

    # ---- Web PHP check (optional) ----
    if [ "$skip_web_php" != true ]; then
        check_web_php "$phpv" add_result
    fi

    # ---- Filesystem perms ----
    for dir in "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_PATH" "$INM_BACKUP_DIRECTORY" "$INM_CACHE_LOCAL_DIRECTORY"; do
        [ -z "$dir" ] && continue
        mkdir -p "$dir" 2>/dev/null
        if touch "$dir/.inm_perm_test" 2>/dev/null; then
            rm -f "$dir/.inm_perm_test"
            add_result OK "FS" "Writable: $dir"
        else
            add_result ERR "FS" "Not writable: $dir"
        fi
    done

    # Try to hydrate DB vars from app .env if missing
    if [ -z "${DB_HOST:-}" ] && [ -f "${INM_ENV_FILE:-}" ]; then
        set -a
        . "$INM_ENV_FILE" 2>/dev/null || true
        set +a
        add_result INFO "DB" "Loaded DB vars from ${INM_ENV_FILE}"
    fi

    # ---- DB connectivity (optional) ----
    if [ "$skip_db" = true ]; then
        add_result WARN "DB" "Connectivity check skipped via --skip-db=true"
    elif [ -n "$DB_HOST" ] && [ -n "$DB_USERNAME" ]; then
        local db_port="${DB_PORT:-3306}"
        add_result INFO "DB" "Target: host=${DB_HOST} port=${db_port} db=${DB_DATABASE:-<unset>} user=${DB_USERNAME}"
        if mysql -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "SELECT 1" >/dev/null 2>&1; then
            add_result OK "DB" "Connection ok to $DB_HOST:${DB_PORT:-3306}"
            # Try to read server/version info
            local dbinfo
            dbinfo=$(mysql -N -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "select @@version, @@version_comment;" 2>/dev/null | head -n1)
            if [ -n "$dbinfo" ]; then
                add_result INFO "DB" "Server: $dbinfo"
            fi
            # DB settings (best effort)
            local settings
            settings=$(mysql -N -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "select @@innodb_file_per_table, @@max_allowed_packet, @@character_set_server, @@collation_server;" 2>/dev/null | head -n1)
            if [ -n "$settings" ]; then
                IFS=$'\t' read -r innodb packet charset coll <<<"$settings"
                add_result INFO "DB" "innodb_file_per_table=${innodb:-?}"
                add_result INFO "DB" "max_allowed_packet=${packet:-?}"
                add_result INFO "DB" "charset=${charset:-?} collation=${coll:-?}"
            fi
            local sql_mode
            sql_mode=$(mysql -N -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USERNAME" ${DB_PASSWORD:+-p"$DB_PASSWORD"} -e "select @@sql_mode;" 2>/dev/null | head -n1)
            [[ -n "$sql_mode" ]] && add_result INFO "DB" "sql_mode=${sql_mode}"
        else
            add_result ERR "DB" "Cannot connect to $DB_HOST:${DB_PORT:-3306} as $DB_USERNAME"
        fi
    else
        add_result ERR "DB" "Missing DB_HOST/DB_USERNAME despite loaded .env"
    fi

    # ---- Cron presence ----
    if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || pgrep -x systemd >/dev/null 2>&1; then
        add_result OK "CRON" "Scheduler service present"
    else
        add_result WARN "CRON" "No cron service detected"
    fi
    if crontab -l 2>/dev/null | grep -q "artisan schedule:run"; then
        add_result OK "CRON" "artisan schedule:run present"
    else
        add_result WARN "CRON" "artisan schedule missing; run core cron install"
    fi

    # ---- Snappdf presence ----
    if [ "$fast" != true ] && [ "$skip_snappdf" != true ]; then
        local snap_dir="${INM_INSTALLATION_PATH%/}/vendor/beganovich/snappdf"
        local tmp_pdf="${INM_CACHE_LOCAL_DIRECTORY:-/tmp}/snappdf_probe.pdf"
        if [ ! -d "$snap_dir" ]; then
            add_result WARN "SNAPPDF" "Not present; run do_snappdf/update"
        elif [ -z "${INM_INSTALLATION_PATH:-}" ] || [ ! -f "${INM_INSTALLATION_PATH%/}/vendor/autoload.php" ]; then
            add_result WARN "SNAPPDF" "Vendor/autoload missing; cannot test snappdf"
        else
            # Try to render a tiny PDF
            local php_probe
            php_probe=$(php -r "require '${INM_INSTALLATION_PATH%/}/vendor/autoload.php'; if (class_exists('Beganovich\\Snappdf\\Snappdf')) { try { (new Beganovich\\Snappdf\\Snappdf)->generate('<h1>probe</h1>', '${tmp_pdf}'); echo 'OK'; } catch (Throwable \$e) { echo 'ERR:' . \$e->getMessage(); } }" 2>/dev/null || true)
            if echo "$php_probe" | grep -q "^OK"; then
                add_result OK "SNAPPDF" "Render ok (${tmp_pdf})"
                rm -f "$tmp_pdf"
            else
                add_result WARN "SNAPPDF" "Render failed (${php_probe:-unknown}); run do_snappdf/update"
            fi
        fi
    fi

    # ---- GitHub reachability ----
    if [ "$fast" != true ] && [ "$skip_github" != true ]; then
        if curl -Is --connect-timeout 5 https://github.com >/dev/null 2>&1; then
            add_result OK "NET" "GitHub reachable"
        else
            add_result WARN "NET" "GitHub not reachable"
        fi
    fi

    # ---- Cache directories ----
    local cache_info_done=false
    if [ -n "${INM_CACHE_GLOBAL_DIRECTORY:-}" ] && [ -d "$INM_CACHE_GLOBAL_DIRECTORY" ] && [ -w "$INM_CACHE_GLOBAL_DIRECTORY" ]; then
        add_result INFO "FS" "Cache (global) writable: $INM_CACHE_GLOBAL_DIRECTORY"
        cache_info_done=true
    elif [ -n "${INM_CACHE_LOCAL_DIRECTORY:-}" ] && [ -d "$INM_CACHE_LOCAL_DIRECTORY" ] && [ -w "$INM_CACHE_LOCAL_DIRECTORY" ]; then
        add_result INFO "FS" "Cache (local) writable: $INM_CACHE_LOCAL_DIRECTORY"
        cache_info_done=true
    fi
    if [ "$cache_info_done" = false ]; then
        add_result WARN "FS" "No writable cache found (global: ${INM_CACHE_GLOBAL_DIRECTORY:-unset}, local: ${INM_CACHE_LOCAL_DIRECTORY:-unset})"
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
                add_result WARN "NET" "APP_URL reachable with -k (self-signed/invalid cert): $app_url_trim"
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

    # Summary table (grouped)
    log info "[PREFLIGHT] Completed: OK=$ok WARN=$warn ERR=$err"
    printf "\n"
    local groups=("CLI" "SYS" "CMD" "NET" "WEB" "PHP" "EXT" "WEBPHP" "FS" "DB" "CRON" "SNAPPDF")
    local idx g printed
    local green="${GREEN:-}"
    local yellow="${YELLOW:-}"
    local red="${RED:-}"
    local reset="${RESET:-}"

    # Global column widths (stable across groups)
    local max_check=5 max_status=6
    for idx in "${!PF_STATUS[@]}"; do
        local check="${PF_CHECK[$idx]}"
        local status="${PF_STATUS[$idx]}"
        (( ${#check}  > max_check )) && max_check=${#check}
        (( ${#status} > max_status )) && max_status=${#status}
    done

    for g in "${groups[@]}"; do
        printed=false
        # Print
        for idx in "${!PF_STATUS[@]}"; do
            if [[ "${PF_CHECK[$idx]}" == "$g" ]]; then
                if [ "$printed" = false ]; then
                    local header="$g"
                    [[ "$g" == "CLI" && -n "${SCRIPT_NAME:-}" ]] && header="${SCRIPT_NAME} CLI"
                    [[ "$g" == "WEB" ]] && header="WEB Server"
                    [[ "$g" == "WEBPHP" ]] && header="WEB PHP"
                    printf "%s\n" "== $header =="
                    printf "%-*s | %-*s | %s\n" "$max_status" "Status" "$max_check" "Check" "Detail"
                    printf "%s\n" "----------------------------------------"
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
                row=$(printf "%s | %-*s | %s" "$status_field" "$max_check" "${PF_CHECK[$idx]}" "${PF_DETAIL[$idx]}")
                printf "%b\n" "$row"
            fi
        done
        if [ "$printed" = true ]; then
            printf "\n"
        fi
    done

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
        ${add_fn:-log info} INFO "WEBPHP" "Using APP_URL: $url"
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
                ${add_fn:-log info} INFO "WEBPHP" "Derived APP_URL from nginx: $url"
            fi
        fi
    fi

    # Fallback to localhost/loopback if still empty
    if [ -z "$url" ]; then
        url="http://127.0.0.1"
        ${add_fn:-log warn} WARN "WEBPHP" "APP_URL not set; probing via $url"
    fi

    if [ ! -d "$webroot" ] || [ ! -w "$webroot" ]; then
        ${add_fn:-log warn} WARN "WEBPHP" "Cannot write probe to webroot: $webroot"
        return 1
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

    local web_php_ver web_php_ini web_mem web_opc web_input web_max_exec web_post_max web_upload_max
    web_php_ver=$(echo "$web_php_out" | grep '^PHP_VERSION=' | cut -d= -f2)
    web_php_ini=$(echo "$web_php_out" | grep '^PHP_INI=' | cut -d= -f2)
    web_user_ini=$(echo "$web_php_out" | grep '^USER_INI=' | cut -d= -f2)
    web_mem=$(echo "$web_php_out" | grep '^MEMORY_LIMIT=' | cut -d= -f2)
    web_opc=$(echo "$web_php_out" | grep '^OPCACHE=' | cut -d= -f2)
    web_input=$(echo "$web_php_out" | grep '^INPUT_VARS=' | cut -d= -f2)
    web_max_exec=$(echo "$web_php_out" | grep '^MAX_EXEC=' | cut -d= -f2)
    web_post_max=$(echo "$web_php_out" | grep '^POST_MAX=' | cut -d= -f2)
    web_upload_max=$(echo "$web_php_out" | grep '^UPLOAD_MAX=' | cut -d= -f2)

    ${add_fn:-log info} INFO "WEBPHP" "Version $web_php_ver (CLI ${php_cli_version:-unknown})"
    ${add_fn:-log info} INFO "WEBPHP" "php.ini $web_php_ini"
    ${add_fn:-log info} INFO "WEBPHP" ".user.ini ${web_user_ini:-<none>}"

    # Evaluate memory_limit / input_vars similar to CLI thresholds
    if [ -n "$web_mem" ] && { [ "$web_mem" = "-1" ] || [ "${web_mem%%M}" -ge 256 ] 2>/dev/null; }; then
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
