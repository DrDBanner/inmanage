#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_PDF_LOADED:-} ]] && return
__SERVICE_PDF_LOADED=1

# ---------------------------------------------------------------------
# do_snappdf()
# Handles Snappdf setup/download when PDF_GENERATOR=snappdf.
# ---------------------------------------------------------------------
do_snappdf() {
    local pdf_gen="${PDF_GENERATOR:-}"
    if [ -z "$pdf_gen" ] && [ -f "${INM_ENV_FILE:-}" ]; then
        pdf_gen=$(grep -E '^PDF_GENERATOR=' "$INM_ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)
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

    find_snappdf_chromium() {
        local dir="$1"
        if [[ -z "$dir" || ! -d "$dir" ]]; then
            return 1
        fi
        find "$dir" -type f \( -name "chrome" -o -name "chromium" -o -name "Chromium" \) -perm -111 2>/dev/null | head -n1
    }

    resolve_snappdf_cache_dir() {
        local base dir parent
        base="$(expand_path_vars "${INM_CACHE_GLOBAL_DIRECTORY:-}")"
        if [[ -n "$base" ]]; then
            dir="${base%/}/snappdf"
            parent="$(dirname "$dir")"
            if [[ -w "$parent" ]]; then
                mkdir -p "$dir" 2>/dev/null || true
                [[ -w "$dir" ]] && printf "%s" "$dir" && return 0
            fi
        fi
        base="$(expand_path_vars "${INM_CACHE_LOCAL_DIRECTORY:-}")"
        if [[ -n "$base" ]]; then
            dir="${base%/}/snappdf"
            mkdir -p "$dir" 2>/dev/null || true
            [[ -w "$dir" ]] && printf "%s" "$dir" && return 0
        fi
        return 1
    }

    local snappdf_bin=""
    snappdf_bin="$(find_snappdf_chromium "$snappdf_versions")"
    if [ -n "$snappdf_bin" ] && [ -x "$snappdf_bin" ]; then
        log debug "[SNAP] Snappdf already present."
        return 0
    fi

    if [ -n "${SNAPPDF_EXECUTABLE_PATH:-}" ]; then
        if [ -x "$SNAPPDF_EXECUTABLE_PATH" ]; then
            log info "[SNAP] SNAPPDF_EXECUTABLE_PATH set to '$SNAPPDF_EXECUTABLE_PATH'; skipping Chromium download (SNAPPDF_SKIP_DOWNLOAD=true)."
            export SNAPPDF_SKIP_DOWNLOAD=true
            skip_download=true
        else
            log warn "[SNAP] SNAPPDF_EXECUTABLE_PATH set but not executable: $SNAPPDF_EXECUTABLE_PATH"
        fi
    elif [ -n "${SNAPPDF_CHROMIUM_PATH:-}" ]; then
        if [ -x "$SNAPPDF_CHROMIUM_PATH" ]; then
            log info "[SNAP] SNAPPDF_CHROMIUM_PATH set to '$SNAPPDF_CHROMIUM_PATH'; skipping Chromium download (SNAPPDF_SKIP_DOWNLOAD=true)."
            export SNAPPDF_SKIP_DOWNLOAD=true
            skip_download=true
        else
            log warn "[SNAP] SNAPPDF_CHROMIUM_PATH set but not executable: $SNAPPDF_CHROMIUM_PATH"
        fi
    fi

    if [ ! -x "$snappdf_cli" ]; then
        log info "[SNAP] Snappdf CLI not found at $snappdf_cli; skipping."
        return 0
    fi

    chmod +x "$snappdf_cli" 2>/dev/null || true

    local existing_bin=""
    existing_bin="$(find_snappdf_chromium "$snappdf_versions")"
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
            log info "[SNAP] Restoring Chromium from cache: $cache_versions"
            if declare -F safe_move_or_copy_and_clean >/dev/null 2>&1; then
                safe_move_or_copy_and_clean "$cache_versions" "$snappdf_versions" copy || log warn "[SNAP] Failed to restore cached Chromium."
            else
                mkdir -p "$snappdf_versions" 2>/dev/null || true
                rsync -a "$cache_versions/." "$snappdf_versions/" 2>/dev/null || log warn "[SNAP] Failed to restore cached Chromium."
            fi
            existing_bin="$(find_snappdf_chromium "$snappdf_versions")"
        fi
    fi

    if [[ -z "$existing_bin" && "$skip_download" != true ]]; then
        log debug "[SNAP] Downloading Chromium via snappdf CLI if needed."
        if spinner_run "Downloading Chromium (snappdf)..." "$INM_PHP_EXECUTABLE" "$snappdf_cli" download >/dev/null 2>&1; then
            log ok "[SNAP] Snappdf download finished."
            local cache_dir=""
            local cache_versions=""
            cache_dir="$(resolve_snappdf_cache_dir 2>/dev/null || true)"
            if [[ -n "$cache_dir" ]]; then
                cache_versions="${cache_dir%/}/versions"
                mkdir -p "$cache_versions" 2>/dev/null || true
                if declare -F safe_move_or_copy_and_clean >/dev/null 2>&1; then
                    safe_move_or_copy_and_clean "$snappdf_versions" "$cache_versions" copy || log warn "[SNAP] Failed to update Chromium cache."
                else
                    rsync -a "$snappdf_versions/." "$cache_versions/" 2>/dev/null || log warn "[SNAP] Failed to update Chromium cache."
                fi
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
    local probe_dir="${INM_CACHE_LOCAL_DIRECTORY:-/tmp}"
    if [[ -n "$probe_dir" ]]; then
        mkdir -p "$probe_dir" 2>/dev/null || true
    fi
    if [[ -z "$probe_dir" || ! -w "$probe_dir" ]]; then
        probe_dir="/tmp"
    fi
    if [[ ! -w "$probe_dir" ]]; then
        log warn "[SNAP] Probe directory not writable; cannot verify snappdf. Set INM_CACHE_LOCAL_DIRECTORY to a writable path."
        return 1
    fi

    local tmp_pdf="${probe_dir%/}/snappdf_probe_$$.pdf"
    local php_exec="${INM_PHP_EXECUTABLE:-php}"
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
