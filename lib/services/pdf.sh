#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_PDF_LOADED:-} ]] && return
__SERVICE_PDF_LOADED=1

# ---------------------------------------------------------------------
# snappdf_read_setting()
# Resolve a Snappdf/App setting from process env first, then app .env.
# Consumes: args: key; env: INM_PATH_APP_ENV_FILE; deps: read_env_value/read_env_value_safe (optional).
# Returns: value on stdout (empty when unset).
# ---------------------------------------------------------------------
snappdf_read_setting() {
    local key="$1"
    local value="${!key:-}"
    if [[ -n "$value" ]]; then
        printf "%s" "$value"
        return 0
    fi

    local env_file="${INM_PATH_APP_ENV_FILE:-}"
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        if declare -F read_env_value >/dev/null 2>&1; then
            value="$(read_env_value "$env_file" "$key" 2>/dev/null || true)"
        elif declare -F read_env_value_safe >/dev/null 2>&1; then
            value="$(read_env_value_safe "$env_file" "$key" 2>/dev/null || true)"
        else
            value="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2-)"
        fi
    fi

    printf "%s" "$value"
}

# ---------------------------------------------------------------------
# snappdf_expand_path()
# Expand HOME placeholders and leading ~ for path-like values.
# Consumes: args: value; deps: expand_path_vars (optional).
# Returns: expanded value on stdout.
# ---------------------------------------------------------------------
snappdf_expand_path() {
    local value="$1"
    if [[ -z "$value" ]]; then
        return 0
    fi

    if declare -F expand_path_vars >/dev/null 2>&1; then
        value="$(expand_path_vars "$value")"
    else
        local home_base="${INM_ORIGINAL_HOME:-${HOME:-}}"
        value="${value/#\~/$home_base}"
        value="${value//\$\{HOME\}/$home_base}"
        value="${value//\$HOME/$home_base}"
    fi

    printf "%s" "$value"
}

# ---------------------------------------------------------------------
# snappdf_is_true()
# Parse truthy env values.
# Consumes: args: value.
# Returns: 0 if value is truthy, 1 otherwise.
# ---------------------------------------------------------------------
snappdf_is_true() {
    local value="${1:-}"
    case "${value,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------
# snappdf_find_chromium_in_dir()
# Find a bundled Chromium/Chrome executable in a directory tree.
# Consumes: args: dir; tools: find.
# Returns: first matching executable path on stdout.
# ---------------------------------------------------------------------
snappdf_find_chromium_in_dir() {
    local dir="$1"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        return 1
    fi
    find "$dir" -type f \( -name "chrome" -o -name "chromium" -o -name "Chromium" -o -name "google-chrome" -o -name "google-chrome-stable" \) -perm -111 2>/dev/null | head -n1
}

# ---------------------------------------------------------------------
# snappdf_find_system_chromium()
# Probe common command names and install paths for Chromium/Chrome.
# Consumes: env: INM_ORIGINAL_HOME/HOME.
# Returns: executable path on stdout (empty when none found).
# ---------------------------------------------------------------------
snappdf_find_system_chromium() {
    local bin=""
    for bin in chrome chromium Chromium google-chrome google-chrome-stable chromium-browser; do
        if command -v "$bin" >/dev/null 2>&1; then
            local resolved=""
            resolved="$(command -v "$bin" 2>/dev/null | head -n1)"
            if [[ -n "$resolved" && -x "$resolved" ]]; then
                printf "%s" "$resolved"
                return 0
            fi
        fi
    done

    local home_base="${INM_ORIGINAL_HOME:-${HOME:-}}"
    local -a candidates=(
        "/usr/local/bin/chrome"
        "/usr/local/bin/chromium"
        "/usr/local/bin/Chromium"
        "${home_base%/}/.local/bin/chrome"
        "${home_base%/}/.local/bin/chromium"
        "${home_base%/}/.local/bin/Chromium"
    )
    local path=""
    for path in "${candidates[@]}"; do
        if [[ -n "$path" && -x "$path" ]]; then
            printf "%s" "$path"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------
# do_snappdf()
# Ensure Snappdf Chromium is available when PDF_GENERATOR=snappdf.
# Consumes: env: PDF_GENERATOR, INM_PATH_APP_ENV_FILE, INM_INSTALLATION_PATH, INM_CACHE_*; deps: spinner_run_mode/expand_path_vars.
# Computes: Chromium download or cache restore.
# Returns: 0 on success or when skipped, non-zero on failure.
# ---------------------------------------------------------------------
do_snappdf() {
    local pdf_gen="${PDF_GENERATOR:-}"
    if [ -z "$pdf_gen" ]; then
        pdf_gen="$(snappdf_read_setting "PDF_GENERATOR")"
    fi
    if [[ "${pdf_gen,,}" != "snappdf" ]]; then
        local gen_label="${pdf_gen:-unset}"
        log info "[SNAP] Snappdf mode: off (PDF_GENERATOR=${gen_label})"
        return 0
    fi

    log info "[SNAP] Installing/Updating Snappdf (headless Chromium) …"

    local snappdf_dir="${INM_INSTALLATION_PATH%/}/vendor/beganovich/snappdf"
    local snappdf_versions="${snappdf_dir%/}/versions"
    local snappdf_cli="${INM_INSTALLATION_PATH%/}/vendor/bin/snappdf"
    local skip_download=false

    resolve_snappdf_cache_dir() {
        local base dir parent
        base="$(expand_path_vars "${INM_CACHE_GLOBAL_DIR:-}")"
        if [[ -n "$base" ]]; then
            dir="${base%/}/snappdf"
            parent="$(dirname "$dir")"
            if [[ -w "$parent" ]]; then
                mkdir -p "$dir" 2>/dev/null || true
                [[ -w "$dir" ]] && printf "%s" "$dir" && return 0
            fi
        fi
        base="$(expand_path_vars "${INM_CACHE_LOCAL_DIR:-}")"
        if [[ -n "$base" ]]; then
            dir="${base%/}/snappdf"
            mkdir -p "$dir" 2>/dev/null || true
            [[ -w "$dir" ]] && printf "%s" "$dir" && return 0
        fi
        return 1
    }

    local snappdf_bin=""
    snappdf_bin="$(snappdf_find_chromium_in_dir "$snappdf_versions")"
    if [ -n "$snappdf_bin" ] && [ -x "$snappdf_bin" ]; then
        log debug "[SNAP] Snappdf already present."
        return 0
    fi

    local snappdf_exec_cfg=""
    local snappdf_chromium_cfg=""
    local snappdf_skip_cfg=""
    snappdf_exec_cfg="$(snappdf_expand_path "$(snappdf_read_setting "SNAPPDF_EXECUTABLE_PATH")")"
    snappdf_chromium_cfg="$(snappdf_expand_path "$(snappdf_read_setting "SNAPPDF_CHROMIUM_PATH")")"
    snappdf_skip_cfg="$(snappdf_read_setting "SNAPPDF_SKIP_DOWNLOAD")"

    if [[ -n "$snappdf_exec_cfg" ]]; then
        export SNAPPDF_EXECUTABLE_PATH="$snappdf_exec_cfg"
    fi
    if [[ -n "$snappdf_chromium_cfg" ]]; then
        export SNAPPDF_CHROMIUM_PATH="$snappdf_chromium_cfg"
    fi

    if [ -n "$snappdf_exec_cfg" ]; then
        if [ -x "$snappdf_exec_cfg" ]; then
            log info "[SNAP] SNAPPDF_EXECUTABLE_PATH set to '$snappdf_exec_cfg'; skipping Chromium download (SNAPPDF_SKIP_DOWNLOAD=true)."
            export SNAPPDF_SKIP_DOWNLOAD=true
            skip_download=true
        else
            log warn "[SNAP] SNAPPDF_EXECUTABLE_PATH set but not executable: $snappdf_exec_cfg"
        fi
    elif [ -n "$snappdf_chromium_cfg" ]; then
        if [ -x "$snappdf_chromium_cfg" ]; then
            log info "[SNAP] SNAPPDF_CHROMIUM_PATH set to '$snappdf_chromium_cfg'; skipping Chromium download (SNAPPDF_SKIP_DOWNLOAD=true)."
            export SNAPPDF_SKIP_DOWNLOAD=true
            skip_download=true
        else
            log warn "[SNAP] SNAPPDF_CHROMIUM_PATH set but not executable: $snappdf_chromium_cfg"
        fi
    fi

    if [[ "$skip_download" != true ]]; then
        local autodetected_chromium=""
        autodetected_chromium="$(snappdf_find_system_chromium 2>/dev/null || true)"
        if [[ -n "$autodetected_chromium" && -x "$autodetected_chromium" ]]; then
            export SNAPPDF_CHROMIUM_PATH="$autodetected_chromium"
            export SNAPPDF_SKIP_DOWNLOAD=true
            skip_download=true
            log info "[SNAP] Auto-detected Chromium/Chrome at '$autodetected_chromium'; skipping download (SNAPPDF_SKIP_DOWNLOAD=true)."
        fi
    fi

    if snappdf_is_true "$snappdf_skip_cfg"; then
        export SNAPPDF_SKIP_DOWNLOAD=true
        skip_download=true
        log info "[SNAP] SNAPPDF_SKIP_DOWNLOAD=true"
    fi

    if [ ! -x "$snappdf_cli" ]; then
        log info "[SNAP] Snappdf CLI not found at $snappdf_cli; skipping."
        return 0
    fi

    chmod +x "$snappdf_cli" 2>/dev/null || true

    local existing_bin=""
    existing_bin="$(snappdf_find_chromium_in_dir "$snappdf_versions")"
    if [[ -n "$existing_bin" ]]; then
        log debug "[SNAP] Chromium already present at $existing_bin"
    else
        local cache_dir=""
        local cache_versions=""
        cache_dir="$(resolve_snappdf_cache_dir 2>/dev/null || true)"
        if [[ -n "$cache_dir" ]]; then
            cache_versions="${cache_dir%/}/versions"
        fi
        if [[ -n "$cache_versions" && -d "$cache_versions" ]]; then
            log debug "[SNAP] Restoring Chromium from cache: $cache_versions"
            safe_move_or_copy_and_clean "$cache_versions" "$snappdf_versions" copy || log warn "[SNAP] Failed to restore cached Chromium."
            existing_bin="$(snappdf_find_chromium_in_dir "$snappdf_versions")"
        fi
    fi

    if [[ -z "$existing_bin" && "$skip_download" == true ]]; then
        local resolved_chromium_path="${SNAPPDF_EXECUTABLE_PATH:-${SNAPPDF_CHROMIUM_PATH:-}}"
        if [[ -z "$resolved_chromium_path" || ! -x "$resolved_chromium_path" ]]; then
            log warn "[SNAP] Download skipped but no executable Chromium/Chrome path is configured."
        fi
    fi

    if [[ -z "$existing_bin" && "$skip_download" != true ]]; then
        log debug "[SNAP] Downloading Chromium via snappdf CLI if needed."
        if spinner_run_mode normal "Downloading Chromium (snappdf)..." "$INM_RUNTIME_PHP_BIN" "$snappdf_cli" download >/dev/null 2>&1; then
            log ok "[SNAP] Snappdf download finished."
            local cache_dir=""
            local cache_versions=""
            cache_dir="$(resolve_snappdf_cache_dir 2>/dev/null || true)"
            if [[ -n "$cache_dir" ]]; then
                cache_versions="${cache_dir%/}/versions"
                mkdir -p "$cache_versions" 2>/dev/null || true
                safe_move_or_copy_and_clean "$snappdf_versions" "$cache_versions" copy || log warn "[SNAP] Failed to update Chromium cache."
            fi
        else
            log warn "[SNAP] Snappdf download failed."
            return 1
        fi
    fi

    if [ ! -f "${INM_INSTALLATION_PATH%/}/vendor/autoload.php" ]; then
        log warn "[SNAP] vendor/autoload.php missing; cannot verify snappdf."
        return 1
    fi
    local probe_dir="${INM_CACHE_LOCAL_DIR:-/tmp}"
    if [[ -n "$probe_dir" ]]; then
        mkdir -p "$probe_dir" 2>/dev/null || true
    fi
    if [[ -z "$probe_dir" || ! -w "$probe_dir" ]]; then
        probe_dir="/tmp"
    fi
    if [[ ! -w "$probe_dir" ]]; then
        log warn "[SNAP] Probe directory not writable; cannot verify snappdf. Set INM_CACHE_LOCAL_DIR to a writable path."
        return 1
    fi

    local tmp_pdf="${probe_dir%/}/snappdf_probe_$$.pdf"
    local php_exec="${INM_RUNTIME_PHP_BIN:-php}"
    local probe_file=""
    probe_file="$(mktemp "${probe_dir%/}/snappdf_probe_XXXX.php" 2>/dev/null || true)"
    if [[ -z "$probe_file" ]]; then
        probe_file="$(mktemp "/tmp/snappdf_probe_XXXX.php" 2>/dev/null || true)"
    fi
    if [[ -z "$probe_file" ]]; then
        log warn "[SNAP] Failed to create probe file; cannot verify snappdf."
        return 1
    fi
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
    log debug "[SNAP] Probe cmd: $php_exec $probe_file"
    local probe_out=""
    if [[ "${DEBUG:-false}" == true ]]; then
        probe_out=$("$php_exec" "$probe_file" 2>&1 || true)
    else
        probe_out=$("$php_exec" "$probe_file" 2>/dev/null || true)
    fi
    log debug "[SNAP] Probe output: ${probe_out:-<empty>}"
    rm -f "$probe_file" 2>/dev/null || true
    if [[ "$probe_out" == OK* ]]; then
        if [[ -s "$tmp_pdf" ]]; then
            log ok "[SNAP] Snappdf render probe ok."
            rm -f "$tmp_pdf" 2>/dev/null || true
            return 0
        fi
        rm -f "$tmp_pdf" 2>/dev/null || true
        log warn "[SNAP] Snappdf probe returned OK but output is missing at $tmp_pdf (probe dir writable: $probe_dir). See https://github.com/beganovich/snappdf (use --debug for details)"
        return 1
    fi
    rm -f "$tmp_pdf" 2>/dev/null || true
    if [[ "$probe_out" == ERR:* ]]; then
        log warn "[SNAP] Snappdf render probe failed (${probe_out}). See https://github.com/beganovich/snappdf (use --debug for details)"
    else
        log warn "[SNAP] Snappdf render probe failed (no output). See https://github.com/beganovich/snappdf (use --debug for details)"
    fi
    return 1
}

# ---------------------------------------------------------------------
# snappdf_warn_missing_libs()
# Emit library hints for Snappdf probe failures.
# Consumes: args: add_fn, chromium_path; tools: ldd; deps: log.
# Returns: 0 always.
# ---------------------------------------------------------------------
snappdf_warn_missing_libs() {
    local add_fn="$1"
    local chromium_path="$2"
    if [[ -z "$chromium_path" ]]; then
        return 0
    fi
    if ! command -v ldd >/dev/null 2>&1; then
        return 0
    fi
    local missing_libs
    missing_libs=$(ldd "$chromium_path" 2>/dev/null | awk '/not found/ {print $1}' | xargs)
    if [ -n "$missing_libs" ]; then
        if [[ -n "$add_fn" ]]; then
            "$add_fn" WARN "SNAPPDF" "Chromium missing libs: ${missing_libs}"
        else
            log warn "[SNAPPDF] Chromium missing libs: ${missing_libs}"
        fi
    fi
}

# ---------------------------------------------------------------------
# snappdf_emit_preflight()
# Run Snappdf preflight probe and emit results (WRITE).
# Consumes: args: add_fn, fast, skip_snappdf; env: INM_PATH_APP_ENV_FILE, INM_INSTALLATION_PATH, INM_CACHE_*; deps: preflight_pick_probe_dir/preflight_write_probe_file/expand_path_vars.
# Returns: 0 after emitting results.
# ---------------------------------------------------------------------
snappdf_emit_preflight() {
    local add_fn="$1"
    local fast="${2:-false}"
    local skip_snappdf="${3:-false}"

    if [[ "$fast" == true || "$skip_snappdf" == true ]]; then
        return 0
    fi

    local pdf_gen="${PDF_GENERATOR:-}"
    if [ -z "$pdf_gen" ]; then
        pdf_gen="$(snappdf_read_setting "PDF_GENERATOR")"
    fi
    if [[ "${pdf_gen,,}" != "snappdf" ]]; then
        "$add_fn" INFO "SNAPPDF" "PDF_GENERATOR not 'snappdf' (current: ${pdf_gen:-unset}); check skipped"
        return 0
    fi

    local snap_dir="${INM_INSTALLATION_PATH%/}/vendor/beganovich/snappdf"
    local snappdf_cli="${INM_INSTALLATION_PATH%/}/vendor/bin/snappdf"
    if [ ! -d "$snap_dir" ]; then
        "$add_fn" WARN "SNAPPDF" "Not present; run do_snappdf/update"
        return 0
    fi
    if [ -z "${INM_INSTALLATION_PATH:-}" ] || [ ! -f "${INM_INSTALLATION_PATH%/}/vendor/autoload.php" ]; then
        "$add_fn" WARN "SNAPPDF" "Vendor/autoload missing; cannot test snappdf"
        return 0
    fi
    if [ ! -x "$snappdf_cli" ]; then
        "$add_fn" WARN "SNAPPDF" "snappdf CLI missing: $snappdf_cli"
    fi

    local chromium_path=""
    local snappdf_exec_cfg=""
    local snappdf_chromium_cfg=""
    snappdf_exec_cfg="$(snappdf_expand_path "$(snappdf_read_setting "SNAPPDF_EXECUTABLE_PATH")")"
    snappdf_chromium_cfg="$(snappdf_expand_path "$(snappdf_read_setting "SNAPPDF_CHROMIUM_PATH")")"
    if [[ -n "$snappdf_exec_cfg" ]]; then
        export SNAPPDF_EXECUTABLE_PATH="$snappdf_exec_cfg"
    fi
    if [[ -n "$snappdf_chromium_cfg" ]]; then
        export SNAPPDF_CHROMIUM_PATH="$snappdf_chromium_cfg"
    fi
    if [ -n "$snappdf_exec_cfg" ]; then
        chromium_path="$snappdf_exec_cfg"
        if [ ! -x "$chromium_path" ]; then
            "$add_fn" WARN "SNAPPDF" "SNAPPDF_EXECUTABLE_PATH not executable: $chromium_path"
        else
            "$add_fn" INFO "SNAPPDF" "Chromium path: $chromium_path (SNAPPDF_EXECUTABLE_PATH)"
        fi
    elif [ -n "$snappdf_chromium_cfg" ]; then
        chromium_path="$snappdf_chromium_cfg"
        if [ ! -x "$chromium_path" ]; then
            "$add_fn" WARN "SNAPPDF" "SNAPPDF_CHROMIUM_PATH not executable: $chromium_path"
        else
            "$add_fn" INFO "SNAPPDF" "Chromium path: $chromium_path (SNAPPDF_CHROMIUM_PATH)"
        fi
    else
        chromium_path="$(snappdf_find_chromium_in_dir "$snap_dir/versions")"
        if [ -n "$chromium_path" ]; then
            "$add_fn" INFO "SNAPPDF" "Chromium path: $chromium_path"
        else
            chromium_path="$(snappdf_find_system_chromium 2>/dev/null || true)"
            if [ -n "$chromium_path" ]; then
                export SNAPPDF_CHROMIUM_PATH="$chromium_path"
                "$add_fn" INFO "SNAPPDF" "Chromium path: $chromium_path (auto-detected)"
            fi
        fi
    fi

    if snappdf_is_true "$(snappdf_read_setting "SNAPPDF_SKIP_DOWNLOAD")"; then
        export SNAPPDF_SKIP_DOWNLOAD=true
        "$add_fn" INFO "SNAPPDF" "SNAPPDF_SKIP_DOWNLOAD=true"
    fi

    local probe_dir=""
    local cache_local=""
    local cache_global=""
    if [ -n "${INM_CACHE_LOCAL_DIR:-}" ]; then
        cache_local="$(expand_path_vars "$INM_CACHE_LOCAL_DIR")"
    fi
    if [ -n "${INM_CACHE_GLOBAL_DIR:-}" ]; then
        cache_global="$(expand_path_vars "$INM_CACHE_GLOBAL_DIR")"
    fi
    preflight_pick_probe_dir probe_dir "$cache_local" "$cache_global" "/tmp"
    if [[ -z "$probe_dir" ]]; then
        "$add_fn" WARN "SNAPPDF" "Probe dir not writable; set INM_CACHE_LOCAL_DIR to a writable path."
        return 0
    fi

    local tmp_pdf="${probe_dir%/}/snappdf_probe.pdf"
    local php_exec="${INM_RUNTIME_PHP_BIN:-php}"
    local probe_file=""
    if ! preflight_write_probe_file "$probe_dir" "snappdf_probe" ".php" probe_file; then
        "$add_fn" WARN "SNAPPDF" "Failed to create probe file; cannot verify snappdf."
        return 0
    fi
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
    local php_probe=""
    if [[ "${DEBUG:-false}" == true ]]; then
        php_probe=$("$php_exec" "$probe_file" 2>&1 || true)
    else
        php_probe=$("$php_exec" "$probe_file" 2>/dev/null || true)
    fi
    log debug "[SNAPPDF] Probe output: ${php_probe:-<empty>}"
    rm -f "$probe_file" 2>/dev/null || true

    if echo "$php_probe" | grep -q "^OK"; then
        if [ -s "$tmp_pdf" ]; then
            "$add_fn" OK "SNAPPDF" "Render ok (probe at ${tmp_pdf})"
            rm -f "$tmp_pdf"
        else
            "$add_fn" WARN "SNAPPDF" "Probe returned OK but output missing (probe dir writable: ${probe_dir}). See https://github.com/beganovich/snappdf (use --debug for details)"
            snappdf_warn_missing_libs "$add_fn" "$chromium_path"
        fi
    elif [[ "$php_probe" == ERR:* ]]; then
        "$add_fn" WARN "SNAPPDF" "Render failed (${php_probe}). See https://github.com/beganovich/snappdf (use --debug for details)"
        snappdf_warn_missing_libs "$add_fn" "$chromium_path"
    else
        "$add_fn" WARN "SNAPPDF" "Render failed (no output). See https://github.com/beganovich/snappdf (use --debug for details)"
        snappdf_warn_missing_libs "$add_fn" "$chromium_path"
    fi
    rm -f "$tmp_pdf" 2>/dev/null || true
}
