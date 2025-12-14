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
        log info "[SNAP] PDF_GENERATOR is not 'snappdf'; skipping snappdf setup."
        return 0
    fi

    log info "[SNAP] Installing/Updating Snappdf (headless Chromium) …"

    local snappdf_dir="${INM_INSTALLATION_PATH%/}/vendor/beganovich/snappdf"
    local snappdf_bin="$snappdf_dir/versions/Chromium.app/Contents/MacOS/Chromium"
    local snappdf_cli="${INM_INSTALLATION_PATH%/}/vendor/bin/snappdf"

    if [ -x "$snappdf_bin" ]; then
        log debug "[SNAP] Snappdf already present."
        return 0
    fi

    if [ -n "${SNAPPDF_CHROMIUM_PATH:-}" ]; then
        log info "[SNAP] SNAPPDF_CHROMIUM_PATH set to '$SNAPPDF_CHROMIUM_PATH'; skipping Chromium download (SNAPPDF_SKIP_DOWNLOAD=true)."
        export SNAPPDF_SKIP_DOWNLOAD=true
    fi

    if [ ! -x "$snappdf_cli" ]; then
        log info "[SNAP] Snappdf CLI not found at $snappdf_cli; skipping."
        return 0
    fi

    chmod +x "$snappdf_cli" 2>/dev/null || true

    log debug "[SNAP] Downloading Chromium via snappdf CLI if needed."
    if "$INM_PHP_EXECUTABLE" "$snappdf_cli" download >/dev/null 2>&1; then
        log ok "[SNAP] Snappdf download finished."
    else
        log warn "[SNAP] Snappdf download failed."
        return 1
    fi
}
