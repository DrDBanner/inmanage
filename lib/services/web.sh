#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_WEB_LOADED:-} ]] && return
__SERVICE_WEB_LOADED=1

# ---------------------------------------------------------------------
# web_emit_preflight()
# Emit webserver details for preflight output.
# Consumes: args: add_fn, install_path; deps: pgrep/service/ss/netstat.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
web_emit_preflight() {
    local add_fn="$1"
    local install_path="$2"
    if [[ -z "$add_fn" ]]; then
        add_fn="log info"
    fi
    if [[ -z "$install_path" ]]; then
        install_path="${INM_INSTALLATION_PATH%/}"
    fi

    local web_is_apache=false
    local apache_running=false
    local nginx_running=false
    local apache_bin=""
    if command -v pgrep >/dev/null 2>&1; then
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
        "$add_fn" INFO "WEB" "Apache${av:+ $av}"
        web_is_apache=true
    elif [[ "$nginx_running" == true ]]; then
        local nv
        nv=$(nginx -v 2>&1 | cut -d: -f2- | xargs)
        "$add_fn" INFO "WEB" "Nginx${nv:+ $nv}"
    else
        "$add_fn" WARN "WEB" "Webserver not detected"
    fi
    if pgrep -f "php-fpm" >/dev/null 2>&1; then
        "$add_fn" INFO "WEB" "php-fpm running"
    fi
    if [ "$web_is_apache" = true ] && [ -n "$install_path" ]; then
        local public_htaccess="${install_path%/}/public/.htaccess"
        if [ -f "$public_htaccess" ]; then
            "$add_fn" OK "WEB" ".htaccess present in public"
        else
            "$add_fn" WARN "WEB" ".htaccess missing in public (Apache detected)"
        fi
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ":80 " && "$add_fn" INFO "WEB" "Port 80 open"
        ss -lnt 2>/dev/null | grep -q ":443 " && "$add_fn" INFO "WEB" "Port 443 open"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -q ":80 " && "$add_fn" INFO "WEB" "Port 80 open"
        netstat -lnt 2>/dev/null | grep -q ":443 " && "$add_fn" INFO "WEB" "Port 443 open"
    fi
}

# ---------------------------------------------------------------------
# webphp_emit_preflight()
# Probe PHP settings via the webserver using a temporary PHP file (WRITE).
# Consumes: args: php_cli_version, add_fn, enforced_owner; env: INM_INSTALLATION_PATH, APP_URL.
# Deps: preflight_ensure_dir/preflight_track_created_dir/preflight_write_probe_file/write_phpinfo_probe/shorten_ini_scanned/php_thresholds/http_fetch/fs_user_can_write.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
webphp_emit_preflight() {
    local php_cli_version="$1"
    local add_fn="$2"
    local enforced_owner="$3"
    local webroot="${INM_INSTALLATION_PATH%/}/public"
    local url=""

    if [ -n "${APP_URL:-}" ]; then
        url="${APP_URL%/}"
    fi

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

    if [ -z "$url" ]; then
        ${add_fn:-log info} INFO "WEBPHP" "APP_URL not set; skipping web probe"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        ${add_fn:-log info} INFO "WEBPHP" "Web probe skipped (curl/wget missing)"
        return 0
    fi

    local app_dir="${INM_INSTALLATION_PATH%/}"
    local app_created=false
    local webroot_created=false
    if [[ -z "$app_dir" ]]; then
        ${add_fn:-log warn} WARN "WEBPHP" "App directory unset; cannot probe web PHP."
        return 1
    fi
    if ! preflight_ensure_dir "$app_dir" app_created; then
        ${add_fn:-log warn} WARN "WEBPHP" "App directory missing and not created: $app_dir"
        return 1
    fi
    if [[ "$app_created" == true ]]; then
        preflight_track_created_dir "$app_dir"
    fi
    if ! preflight_ensure_dir "$webroot" webroot_created; then
        ${add_fn:-log warn} WARN "WEBPHP" "Webroot missing and not created: $webroot"
        return 1
    fi
    if [[ "$webroot_created" == true ]]; then
        preflight_track_created_dir "$webroot"
    fi

    local probe_file=""
    if ! preflight_write_probe_file "$webroot" "inm_php_probe" ".php" probe_file; then
        ${add_fn:-log warn} WARN "WEBPHP" "Cannot write probe to webroot: $webroot (user: $(whoami)). Hint: chown -R ${enforced_owner:-www-data:www-data} \"$webroot\" or run with --override_enforced_user=true to adjust perms."
        return 1
    fi
    local probe_url=""
    probe_url="${url%/}/$(basename "$probe_file")"
    write_phpinfo_probe "$probe_file"
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        if [[ -n "$enforced_owner" ]]; then
            chown "$enforced_owner" "$probe_file" 2>/dev/null || true
        fi
    fi
    chmod 644 "$probe_file" 2>/dev/null || true

    local web_php_out=""
    http_fetch_with_args "$probe_url" web_php_out true -L

    rm -f "$probe_file"

    if [ -z "$web_php_out" ]; then
        ${add_fn:-log warn} WARN "WEBPHP" "Could not retrieve via ${probe_url}"
        return 1
    fi
    if ! echo "$web_php_out" | grep -q 'PHP_VERSION='; then
        if [[ "${DEBUG:-false}" == true ]]; then
            log debug "[WEBPHP] Probe output (first 200 bytes): $(printf '%s' "$web_php_out" | head -c 200)"
        fi
        ${add_fn:-log warn} WARN "WEBPHP" "Probe did not return PHP details via ${probe_url}"
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
        [[ -n "$web_ini_short" ]] && ${add_fn:-log info} INFO "WEBPHP" "ini scanned ${web_ini_short}"
    fi
    ${add_fn:-log info} INFO "WEBPHP" ".user.ini $web_user_ini_detail"
    if [[ "$web_user_ini_detail" == "<none>" || "$web_user_ini_detail" == *"public: missing"* ]]; then
        ${add_fn:-log info} INFO "WEBPHP" "Tip: write .user.ini with 'inm env user-ini apply'"
    fi

    php_thresholds "${add_fn:-add_result}" "WEBPHP" "$web_mem" "$web_input" "$web_opc" "$web_max_exec" "$web_max_input_time" "$web_post_max" "$web_upload_max" "$web_realpath_cache" "$web_display_errors" "$web_error_reporting" "$web_proc_open" "$web_exec" "$web_fpassthru" "$web_open_basedir" "$web_disable_functions"

    if [ -n "$php_cli_version" ] && [ -n "$web_php_ver" ] && [ "$php_cli_version" != "$web_php_ver" ]; then
        ${add_fn:-log warn} WARN "WEBPHP" "CLI $php_cli_version differs from Web $web_php_ver"
    fi
}
