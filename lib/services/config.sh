#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_CONFIG_LOADED:-} ]] && return
__SERVICE_CONFIG_LOADED=1

# ---------------------------------------------------------------------
# write_config_setting()
# ---------------------------------------------------------------------
write_config_setting() {
    local key="$1"
    local value="${default_settings[$key]}"
    local inline_comment=""
    if [ -n "${default_inline_comments[$key]+_}" ]; then
        inline_comment="${default_inline_comments[$key]}"
    fi
    if [ -n "$inline_comment" ]; then
        printf '%s="%s" # %s\n' "$key" "$value" "$inline_comment" >> "$INM_SELF_ENV_FILE"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$INM_SELF_ENV_FILE"
    fi
}

# ---------------------------------------------------------------------
# write_config_defaults()
# ---------------------------------------------------------------------
write_config_defaults() {
    local key
    if [ "${#default_settings_order[@]}" -gt 0 ]; then
        for key in "${default_settings_order[@]}"; do
            if [ -n "${default_settings[$key]+_}" ]; then
                write_config_setting "$key"
            fi
        done
    fi

    local remaining_keys=()
    for key in "${!default_settings[@]}"; do
        if [[ " ${default_settings_order[*]} " != *" ${key} "* ]]; then
            remaining_keys+=("$key")
        fi
    done
    if [ "${#remaining_keys[@]}" -gt 0 ]; then
        IFS=$'\n' remaining_keys=($(printf '%s\n' "${remaining_keys[@]}" | sort))
        unset IFS
        for key in "${remaining_keys[@]}"; do
            write_config_setting "$key"
        done
    fi
}

# ---------------------------------------------------------------------
# persist_derived_config()
# ---------------------------------------------------------------------
persist_derived_config() {
    log debug "[PDC] Attempting to persist default configuration"

    if [ "${NAMED_ARGS[auto_create_config]}" != true ]; then
        log debug "[PDC] Skipped: auto_create_config is not true"
        return 0
    fi

    INM_SELF_ENV_FILE="${NAMED_ARGS[config]:-${INM_SELF_ENV_FILE:-$INM_DEFAULT_SELF_ENV_FILE}}"
    local target_dir
    target_dir="$(dirname "$INM_SELF_ENV_FILE")"

    mkdir -p "$target_dir" 2>/dev/null || {
        log err "[PDC] Could not create config target directory: $target_dir"
        return 1
    }

    if [ -f "$INM_SELF_ENV_FILE" ]; then
        log note "[PDC] Config already exists: $INM_SELF_ENV_FILE. Skipping auto-persist."
        return 0
    fi

    touch "$INM_SELF_ENV_FILE" 2>/dev/null || {
        log err "[PDC] Failed to create config file: $INM_SELF_ENV_FILE"
        return 1
    }

    log info "[PDC] Writing derived config to: $INM_SELF_ENV_FILE"

    write_config_defaults
    if ! grep -q "^INM_CLI_COMPATIBILITY=" "$INM_SELF_ENV_FILE"; then
        echo "INM_CLI_COMPATIBILITY=\"new\"" >> "$INM_SELF_ENV_FILE"
    fi

    chmod 644 "$INM_SELF_ENV_FILE" 2>/dev/null
    log ok "[PDC] Config persisted successfully"
    warn_cli_config_owner_mismatch "$INM_SELF_ENV_FILE"

    return 0
}

_config_read_value() {
    local key="$1"
    local file="$2"
    local line val
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1)"
    [[ -z "$line" ]] && return 0
    val="${line#*=}"
    val="${val%%#*}"
    val="$(printf "%s" "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    val="${val%\"}"
    val="${val#\"}"
    printf "%s" "$val"
}

config_expected_owner() {
    local config_file="$1"
    local user group
    user="$(_config_read_value "INM_ENFORCED_USER" "$config_file")"
    if [[ -z "$user" ]]; then
        return 0
    fi
    group="$(_config_read_value "INM_ENFORCED_GROUP" "$config_file")"
    if [[ -z "$group" ]]; then
        group="$(id -gn "$user" 2>/dev/null || true)"
        [[ -z "$group" ]] && group="$user"
    fi
    printf "%s:%s" "$user" "$group"
}

warn_cli_config_owner_mismatch() {
    local config_file="$1"
    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        return 0
    fi
    local expected current
    expected="$(config_expected_owner "$config_file")"
    if [[ -z "$expected" ]]; then
        return 0
    fi
    if declare -F _fs_get_owner >/dev/null 2>&1; then
        current="$(_fs_get_owner "$config_file")"
    else
        current="$(stat -c '%U:%G' "$config_file" 2>/dev/null || stat -f '%Su:%Sg' "$config_file" 2>/dev/null || echo "")"
    fi
    if [[ -n "$current" && "$current" != "$expected" ]]; then
        log warn "[CFG] Config owner mismatch: $config_file (owner=$current, expected=$expected). Consider: sudo chown $expected \"$config_file\""
    fi
}

# ---------------------------------------------------------------------
# create_own_config()
# ---------------------------------------------------------------------
create_own_config() {
    log debug "[COC] init."
    INM_SELF_ENV_FILE="${NAMED_ARGS[target_file]:-${INM_SELF_ENV_FILE:-$INM_DEFAULT_SELF_ENV_FILE}}"

    local target_dir
    target_dir="$(dirname "$INM_SELF_ENV_FILE")"
    mkdir -p "$target_dir" >/dev/null 2>&1 || {
        log err "[COC] Could not create directory '$target_dir'"
        exit 1
    }

    # shellcheck disable=SC2154
    if [ -f "$INM_SELF_ENV_FILE" ] && [ "$force_update" != true ]; then
        log debug "[COC] Config file '$INM_SELF_ENV_FILE' already exists. Use create_config --force to recreate."
        return 0
    fi

    if [ -f "$INM_SELF_ENV_FILE" ]; then
        cp -f "$INM_SELF_ENV_FILE" "$INM_SELF_ENV_FILE.bak.$(date +%s)" >/dev/null 2>&1 || {
            log warn "[COC] Could not create backup of existing config."
        }
        rm -f "$INM_SELF_ENV_FILE" >/dev/null 2>&1 || {
            log err "[COC] Could not remove existing config file '$INM_SELF_ENV_FILE'. Aborting."
            exit 1
        }
    fi

    if ! touch "$INM_SELF_ENV_FILE"; then
        log err "[COC] Error: Could not write to '$INM_SELF_ENV_FILE'. Aborting."
        exit 1
    fi

    log info "[COC] Creating configuration in: $INM_SELF_ENV_FILE"
    echo -e "\n${GREEN}========== Install Wizard ==========${NC}\n"

    local non_interactive=true
    # shellcheck disable=SC2154
    for key in "${prompt_order[@]}"; do
        if [ -z "${NAMED_ARGS[$key]+_}" ]; then
            non_interactive=false
            break
        fi
    done

    if [ "$non_interactive" = false ]; then
        log note "Just press [ENTER] to accept default values."
        for key in "${prompt_order[@]}"; do
            local defval="${default_settings[$key]}"
            local prompt_text="${prompt_texts[$key]:-"Provide value for $key:"}"
            read -r -p "$(echo -e "${GREEN}\n${prompt_text}\n${NC}${GRAY}[$defval]${NC}${RESET} > ")" input
            # shellcheck disable=SC2004
            default_settings[$key]="${input:-$defval}"
        done
    else
        log info "[COC] All values provided via --key=value args. Skipping interactive prompt."
        for key in "${prompt_order[@]}"; do
            # shellcheck disable=SC2004
            default_settings[$key]="${NAMED_ARGS[$key]:-${default_settings[$key]}}"
        done
    fi

    for key in "${!default_settings[@]}"; do
        if [ -n "${NAMED_ARGS[$key]+_}" ]; then
            default_settings[$key]="${NAMED_ARGS[$key]}"
        fi
    done

    write_config_defaults

    for key in "${!NAMED_ARGS[@]}"; do
        if [ -z "${default_settings[$key]+_}" ]; then
            echo "$key=\"${NAMED_ARGS[$key]}\"" >> "$INM_SELF_ENV_FILE"
        fi
    done
    if ! grep -q "^INM_CLI_COMPATIBILITY=" "$INM_SELF_ENV_FILE"; then
        echo "INM_CLI_COMPATIBILITY=\"new\"" >> "$INM_SELF_ENV_FILE"
    fi

    chmod 644 "$INM_SELF_ENV_FILE" 2>/dev/null
    log ok "$INM_SELF_ENV_FILE has been created and configured."

    load_env_file_raw "$INM_SELF_ENV_FILE"
    warn_cli_config_owner_mismatch "$INM_SELF_ENV_FILE"

    if [ -z "$INM_BASE_DIRECTORY" ]; then
        log err "[COC] 'INM_BASE_DIRECTORY' is empty. Aborting."
        exit 1
    fi

    INM_ENV_EXAMPLE_FILE="${INM_BASE_DIRECTORY%/}/.inmanage/.env.example"
    log debug "[COC] INM_ENV_EXAMPLE_FILE set to $INM_ENV_EXAMPLE_FILE"

    log info "[COC] Downloading .env.example for provisioning"
    curl -sL ${CURL_AUTH_FLAG:+$CURL_AUTH_FLAG} \
        "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" \
        -o "$INM_ENV_EXAMPLE_FILE" || {
            log err "[COC] Failed to download .env.example"
            exit 1
        }

    if [ -f "$INM_ENV_EXAMPLE_FILE" ]; then
        local sed_expr='/^DB_PORT=/a DB_ELEVATED_USERNAME=\nDB_ELEVATED_PASSWORD='
        if ! sed -i '' -e "$sed_expr" "$INM_ENV_EXAMPLE_FILE" 2>/dev/null; then
            sed -i -e "$sed_expr" "$INM_ENV_EXAMPLE_FILE" 2>/dev/null || {
                log warn "[COC] Failed to update DB_ELEVATED_* entries in $INM_ENV_EXAMPLE_FILE"
            }
        fi
    fi

    check_provision_file
}
