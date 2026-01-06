#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__HELPER_COMPAT_LOADED:-} ]] && return
__HELPER_COMPAT_LOADED=1

# ---------------------------------------------------------------------
# compat_init()
# Detect distro traits and set compatibility defaults.
# Consumes: /etc/os-release, uname, tar/sed/sha256/sudo availability.
# Computes: INM_OS_ID, INM_OS_VERSION, INM_SED_EXT_FLAG, INM_SHA256_MODE, INM_TAR_EXTRACT_FLAGS, INM_SUDO_BIN.
# Returns: 0 after initialization.
# ---------------------------------------------------------------------
compat_init() {
    [[ -n ${__INM_COMPAT_INITIALIZED:-} ]] && return 0
    __INM_COMPAT_INITIALIZED=1

    export INM_OS_ID=""
    export INM_OS_VERSION=""
    if [ -r /etc/os-release ]; then
        while IFS='=' read -r key val; do
            case "$key" in
                ID|VERSION_ID)
                    val="${val%\"}"
                    val="${val#\"}"
                    if [ "$key" = "ID" ]; then
                        INM_OS_ID="$val"
                    else
                        INM_OS_VERSION="$val"
                    fi
                    ;;
            esac
        done < /etc/os-release
    fi
    if [ -z "$INM_OS_ID" ]; then
        INM_OS_ID="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    fi

    export INM_SED_EXT_FLAG="-E"
    if ! printf 'x' | sed -E 's/x/y/' >/dev/null 2>&1; then
        if printf 'x' | sed -r 's/x/y/' >/dev/null 2>&1; then
            INM_SED_EXT_FLAG="-r"
        else
            INM_SED_EXT_FLAG=""
        fi
    fi

    export INM_SHA256_MODE=""
    if command -v sha256sum >/dev/null 2>&1; then
        INM_SHA256_MODE="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        INM_SHA256_MODE="shasum"
    elif command -v sha256 >/dev/null 2>&1; then
        INM_SHA256_MODE="sha256"
    fi

    local tar_help=""
    tar_help="$(tar --help 2>/dev/null || true)"
    local tar_flags=()
    if printf "%s" "$tar_help" | grep -q -- '--no-same-owner'; then
        tar_flags+=("--no-same-owner")
    fi
    if printf "%s" "$tar_help" | grep -q -- '--no-same-permissions'; then
        tar_flags+=("--no-same-permissions")
    fi
    export INM_TAR_EXTRACT_FLAGS="${tar_flags[*]}"

    if command -v sudo >/dev/null 2>&1; then
        export INM_SUDO_BIN="sudo"
    elif command -v doas >/dev/null 2>&1; then
        export INM_SUDO_BIN="doas"
    else
        export INM_SUDO_BIN=""
    fi
}

# ---------------------------------------------------------------------
# compat_compute_sha256()
# Compute a SHA256 hash using the available tool.
# Consumes: args: file; env: INM_SHA256_MODE.
# Computes: SHA256 checksum.
# Returns: prints checksum or non-zero on failure.
# ---------------------------------------------------------------------
compat_compute_sha256() {
    local file="$1"
    case "$INM_SHA256_MODE" in
        sha256sum) sha256sum "$file" | awk '{print $1}' ;;
        shasum) shasum -a 256 "$file" | awk '{print $1}' ;;
        sha256) sha256 -q "$file" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------
# compat_write_sha256_file()
# Write a .sha256 file for a given file.
# Consumes: args: file, out (optional); deps: compat_compute_sha256.
# Computes: checksum file content.
# Returns: 0 on success, 1 on failure.
# ---------------------------------------------------------------------
compat_write_sha256_file() {
    local file="$1"
    local out="${2:-${file}.sha256}"
    local sum
    sum="$(compat_compute_sha256 "$file")" || return 1
    printf "%s  %s\n" "$sum" "$(basename "$file")" > "$out"
}
