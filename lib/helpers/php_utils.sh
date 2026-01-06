#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__PHP_UTILS_LOADED:-} ]] && return
__PHP_UTILS_LOADED=1

# ---------------------------------------------------------------------
# write_phpinfo_probe()
# Write a PHP probe file to output selected phpinfo values.
# Consumes: args: path.
# Computes: PHP probe file contents.
# Returns: 0 after writing.
# ---------------------------------------------------------------------
write_phpinfo_probe() {
    local path="$1"
    cat > "$path" <<'PHP'
<?php
$values = [
    'PHP_VERSION' => PHP_VERSION,
    'PHP_SAPI' => php_sapi_name(),
    'PHP_INI' => php_ini_loaded_file() ?: '',
    'PHP_INI_SCAN_DIR' => get_cfg_var('cfg_file_scan_dir') ?: '',
    'PHP_INI_SCANNED' => php_ini_scanned_files() ?: '',
    'USER_INI' => get_cfg_var('user_ini.filename') ?: '',
    'MEMORY_LIMIT' => ini_get('memory_limit'),
    'MAX_INPUT_VARS' => ini_get('max_input_vars'),
    'OPCACHE' => ini_get('opcache.enable'),
    'MAX_EXEC' => ini_get('max_execution_time'),
    'MAX_INPUT_TIME' => ini_get('max_input_time'),
    'POST_MAX' => ini_get('post_max_size'),
    'UPLOAD_MAX' => ini_get('upload_max_filesize'),
    'REALPATH_CACHE_SIZE' => ini_get('realpath_cache_size'),
    'DISPLAY_ERRORS' => ini_get('display_errors'),
    'ERROR_REPORTING' => ini_get('error_reporting'),
    'OPEN_BASEDIR' => ini_get('open_basedir'),
    'DISABLE_FUNCTIONS' => ini_get('disable_functions'),
    'PROC_OPEN' => function_exists('proc_open') ? '1' : '0',
    'EXEC' => function_exists('exec') ? '1' : '0',
    'FPASSTHRU' => function_exists('fpassthru') ? '1' : '0',
];

foreach ($values as $key => $val) {
    $val = trim(str_replace("\n", " ", (string) $val));
    echo $key . "=" . $val . "\n";
}
PHP
}

# ---------------------------------------------------------------------
# shorten_ini_scanned()
# Shorten the list of scanned ini files for display.
# Consumes: args: scanned, max_items.
# Computes: shortened list with totals.
# Returns: prints summary string.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# phpinfo_probe_cli()
# Execute the phpinfo probe with CLI PHP.
# Consumes: deps: write_phpinfo_probe; env: PHP path.
# Computes: probe output.
# Returns: prints probe output to stdout.
# ---------------------------------------------------------------------
phpinfo_probe_cli() {
    local tmp_file
    tmp_file="$(mktemp)" || return 1
    write_phpinfo_probe "$tmp_file"
    php "$tmp_file" 2>/dev/null || true
    rm -f "$tmp_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------
# php_emit()
# Emit a PHP check entry via the provided add_fn callback.
# Consumes: args: add_fn, status, tag, msg.
# Computes: check output line.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
php_emit() {
    local add_fn="$1"
    local status="$2"
    local tag="$3"
    local msg="$4"
    "$add_fn" "$status" "$tag" "$msg"
}

# ---------------------------------------------------------------------
# php_thresholds()
# Apply threshold checks to PHP configuration values.
# Consumes: args: add_fn, tag, values...; deps: mem_to_mb/php_emit.
# Computes: check status lines.
# Returns: 0 after emitting checks.
# ---------------------------------------------------------------------
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
