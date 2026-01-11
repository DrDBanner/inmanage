#!/usr/bin/env bash

# ---------------------------------------------------------------------
# file_read_state()
# Classify file readability state.
# Consumes: args: path; tools: stat.
# Computes: readable/exists_unreadable/permission/missing.
# Returns: state on stdout.
# ---------------------------------------------------------------------
file_read_state() {
    local path="$1"
    if [ -r "$path" ]; then
        echo "readable"
        return 0
    fi
    if [ -e "$path" ]; then
        echo "exists_unreadable"
        return 0
    fi
    local stat_err=""
    stat_err="$(stat "$path" 2>&1 || true)"
    if echo "$stat_err" | grep -qi "permission denied"; then
        echo "permission"
        return 0
    fi
    echo "missing"
    return 0
}

# ---------------------------------------------------------------------
# res_log_warn_pre_switch()
# Log warnings, suppressing before user switch if configured.
# Consumes: args: message; deps: should_suppress_pre_switch_logs (optional).
# Computes: log routing.
# Returns: 0 always.
# ---------------------------------------------------------------------
res_log_warn_pre_switch() {
    local message="$1"
    if should_suppress_pre_switch_logs; then
        log debug "$message"
    else
        log warn "$message"
    fi
}

# ---------------------------------------------------------------------
# res_log_missing_env()
# Log missing .env with context-sensitive severity.
# Consumes: args: message; env: CMD_CONTEXT/CMD_ACTION.
# Computes: debug vs warn routing.
# Returns: 0 always.
# ---------------------------------------------------------------------
res_log_missing_env() {
    local message="$1"
    if [[ "${CMD_CONTEXT:-}" == "core" && ( "${CMD_ACTION:-}" == "install" || "${CMD_ACTION:-}" == "provision" ) ]]; then
        log debug "$message"
        return 0
    fi
    res_log_warn_pre_switch "$message"
}

# ---------------------------------------------------------------------
# res_warn_env_unreadable()
# Log unreadable .env once.
# Consumes: args: message; env: INM_ENV_WARNED.
# Computes: warn once then debug.
# Returns: 0 always.
# ---------------------------------------------------------------------
res_warn_env_unreadable() {
    local message="$1"
    if [[ "${INM_ENV_WARNED:-false}" == true ]]; then
        log debug "$message"
        return 0
    fi
    res_log_warn_pre_switch "$message"
    INM_ENV_WARNED=true
}

# ---------------------------------------------------------------------
# resolve_env_paths()
# Detect Invoice Ninja .env and related paths via flags or heuristic.
# Consumes: args: NAMED_ARGS; env: INM_*; deps: file_read_state/ensure_trailing_slash/compute_installation_path.
# Computes: INM_SELF_ENV_FILE, INM_ENV_FILE, INM_BASE_DIRECTORY, INM_INSTALLATION_DIRECTORY, INM_INSTALLATION_PATH.
# Returns: 0 always (logs warnings on issues).
# ---------------------------------------------------------------------
resolve_env_paths() {
    log debug "[RES] Resolving environment paths... (args: $*)"

    unset -v INM_SELF_ENV_FILE INM_PROVISION_ENV_FILE INM_ENV_FILE INM_BASE_DIRECTORY INM_INSTALLATION_DIRECTORY INM_INSTALLATION_PATH

    if [ -n "${NAMED_ARGS[ninja_location]}" ]; then
        local ninja_dir="${NAMED_ARGS[ninja_location]}"
        # Treat boolean/empty values as unset
        if [[ "$ninja_dir" == "true" || "$ninja_dir" == "false" || -z "$ninja_dir" ]]; then
            log debug "[RES] Ignoring --ninja-location with non-path value: $ninja_dir"
            ninja_dir=""
        elif [[ "$ninja_dir" == --* ]] || [[ "$ninja_dir" != */* && "$ninja_dir" != .* ]]; then
            log debug "[RES] Ignoring invalid --ninja-location value: $ninja_dir"
            ninja_dir=""
        else
            local env_state
            env_state="$(file_read_state "$ninja_dir/.env")"
            if [ "$env_state" = "readable" ]; then
                INM_BASE_DIRECTORY="$(dirname "$(realpath "$ninja_dir")")/"
                INM_INSTALLATION_DIRECTORY="$(basename "$ninja_dir")"
                INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
                INM_ENV_FILE="$ninja_dir/.env"
                log debug "[RES] Using .env from --ninja-location: $INM_ENV_FILE"
                if [ -z "${INM_SELF_ENV_FILE:-}" ] && [ -f "$INM_BASE_DIRECTORY/.inmanage/.env.inmanage" ]; then
                    INM_SELF_ENV_FILE="$INM_BASE_DIRECTORY/.inmanage/.env.inmanage"
                fi
                return 0
            elif [ "$env_state" = "exists_unreadable" ] || [ "$env_state" = "permission" ]; then
                INM_ENV_FILE="$ninja_dir/.env"
                res_warn_env_unreadable "[RES] App .env not readable at $INM_ENV_FILE (permission issue)."
                return 0
            else
                log warn "[RES] No .env found in --ninja-location: $ninja_dir (falling back to auto-detect)"
                ninja_dir=""
            fi
        fi
    fi

    # If a local .inmanage/.env.inmanage exists, load it early to derive base/install
    if [ -f "$PWD/.inmanage/.env.inmanage" ]; then
        if [ -r "$PWD/.inmanage/.env.inmanage" ]; then
            log debug "[RES] Loading local config: $PWD/.inmanage/.env.inmanage"
            # shellcheck source=/dev/null
            source "$PWD/.inmanage/.env.inmanage"
            INM_SELF_ENV_FILE="$PWD/.inmanage/.env.inmanage"
        else
            log warn "[RES] Local config not readable: $PWD/.inmanage/.env.inmanage"
            INM_SELF_ENV_FILE="$PWD/.inmanage/.env.inmanage"
        fi
        if [ -n "${INM_BASE_DIRECTORY:-}" ] && [ -n "${INM_INSTALLATION_DIRECTORY:-}" ]; then
            INM_BASE_DIRECTORY="$(ensure_trailing_slash "${INM_BASE_DIRECTORY}")"
            INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
            INM_ENV_FILE="${INM_INSTALLATION_PATH%/}/.env"
            log debug "[RES] Derived from config: base=$INM_BASE_DIRECTORY install=$INM_INSTALLATION_DIRECTORY env=$INM_ENV_FILE"
            local env_state
            env_state="$(file_read_state "$INM_ENV_FILE")"
            if [ "$env_state" = "readable" ]; then
                log debug "[RES] Using .env from existing project config, skipping discovery."
                return 0
            elif [ "$env_state" = "exists_unreadable" ] || [ "$env_state" = "permission" ]; then
                res_warn_env_unreadable "[RES] App .env not readable at $INM_ENV_FILE (permission issue); skipping discovery."
                return 0
            else
                res_log_missing_env "[RES] App .env not found at $INM_ENV_FILE (from config); continuing discovery."
            fi
        fi
    fi

    local candidate_paths=(
        "$PWD/.inmanage"
        "$PWD"
        "$PWD/invoiceninja"   # common default install dir
        "$PWD/ninja"
        "$PWD/../.inmanage"
        "$PWD/.."
        "$HOME/.inmanage"
    )

    local candidates=()
    local unreadable_candidates=()
    for dir in "${candidate_paths[@]}"; do
        local env_path="$dir/.env"
        local env_state
        env_state="$(file_read_state "$env_path")"
        if [ "$env_state" = "readable" ]; then
            candidates+=("$env_path")
        elif [ "$env_state" = "exists_unreadable" ] || [ "$env_state" = "permission" ]; then
            unreadable_candidates+=("$env_path")
            if [[ "${INM_ENV_WARNED:-false}" != true ]]; then
                res_warn_env_unreadable "[RES] App .env not readable at $env_path (permission issue)."
                INM_ENV_WARNED=true
            fi
        fi
        log debug "[RES] Checked for .env in: $dir"
    done

    if [ ${#candidates[@]} -eq 0 ]; then
        if [ ${#unreadable_candidates[@]} -gt 0 ]; then
            INM_ENV_FILE="${unreadable_candidates[0]}"
            res_warn_env_unreadable "[RES] App .env not readable: $INM_ENV_FILE (permission issue)."
            return 0
        fi
        if [ -z "${INM_ENV_FILE:-}" ]; then
            # Last resort: derive from base/install if set, otherwise warn only
            if [ -n "${INM_BASE_DIRECTORY:-}" ] && [ -n "${INM_INSTALLATION_DIRECTORY:-}" ]; then
                INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"
                INM_ENV_FILE="${INM_INSTALLATION_PATH%/}/.env"
                log warn "[RES] No .env found; deriving path: $INM_ENV_FILE"
            else
                log warn "[RES] Could not find a usable .env file. Please specify --ninja-location=…"
                return 0
            fi
        fi
    elif [ ${#candidates[@]} -eq 1 ]; then
        INM_ENV_FILE="${candidates[0]}"
        log debug "[RES] Found .env: $INM_ENV_FILE"
    else
        if [ "${NAMED_ARGS[force]}" = true ]; then
            log err "[RES] Multiple .env files found, but --force was used. Cannot decide."
            exit 1
        fi
        INM_ENV_FILE="$(select_from_candidates "Select your Invoice Ninja .env file:" "${candidates[@]}")" || exit 1
    fi

    if [ -n "${INM_ENV_FILE:-}" ]; then
        if command -v realpath >/dev/null 2>&1; then
            INM_ENV_FILE="$(realpath "$INM_ENV_FILE" 2>/dev/null || echo "$INM_ENV_FILE")"
        fi
        INM_BASE_DIRECTORY="$(dirname "$(dirname "$INM_ENV_FILE")")/"
        INM_INSTALLATION_DIRECTORY="$(basename "$(dirname "$INM_ENV_FILE")")"
        INM_INSTALLATION_PATH="$(compute_installation_path "$INM_BASE_DIRECTORY" "$INM_INSTALLATION_DIRECTORY")"

        log debug "[RES] Detected base: $INM_BASE_DIRECTORY"
        log debug "[RES] Detected install dir: $INM_INSTALLATION_DIRECTORY"
        log debug "[RES] Install path: $INM_INSTALLATION_PATH"
        log debug "[RES] Using: $INM_ENV_FILE"
    fi

    # Prefer config alongside the base directory (not inside Invoice Ninja)
    # Respect explicit override via --config and allow relocatable config roots/basenames
    if [ -n "${NAMED_ARGS[config]:-}" ]; then
        # Ignore boolean/empty config values
        case "${NAMED_ARGS[config]}" in
            true|false|"") ;;
            *) INM_SELF_ENV_FILE="${NAMED_ARGS[config]}" ;;
        esac
    elif [ -z "${INM_SELF_ENV_FILE:-}" ] || [ ! -f "$INM_SELF_ENV_FILE" ]; then
        local config_root="${NAMED_ARGS[config_root]:-${INM_CONFIG_ROOT:-.inmanage}}"
        local config_basename="${INM_SELF_ENV_BASENAME:-.env.inmanage}"
        local provision_basename="${INM_PROVISION_ENV_BASENAME:-.env.provision}"

        # Anchor relative config root to detected base directory
        if [[ "$config_root" != /* ]]; then
            config_root="${INM_BASE_DIRECTORY%/}/${config_root#/}"
        fi

        local cfg_candidates=(
            "${config_root%/}/${config_basename}"
            "${INM_BASE_DIRECTORY%/}/${config_basename}"          # backward compat if user placed it here
        )
        for cfg in "${cfg_candidates[@]}"; do
            if [ -f "$cfg" ]; then
                INM_SELF_ENV_FILE="$cfg"
                break
            fi
        done
        # If none exist, default to preferred location next to config_root
        if [ -z "${INM_SELF_ENV_FILE:-}" ]; then
            INM_SELF_ENV_FILE="${config_root%/}/${config_basename}"
        fi

        if [[ -z "${INM_PROVISION_ENV_FILE:-}" ]]; then
            INM_PROVISION_ENV_FILE="${config_root%/}/${provision_basename}"
        elif [[ "$INM_PROVISION_ENV_FILE" != /* ]]; then
            INM_PROVISION_ENV_FILE="${config_root%/}/${INM_PROVISION_ENV_FILE#/}"
        fi
    fi

    log debug "[RES] Config file resolved: ${INM_SELF_ENV_FILE:-<unset>}"
}
