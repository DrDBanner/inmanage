#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_CONFIG_LOADED:-} ]] && return
__SERVICE_CONFIG_LOADED=1

# ---------------------------------------------------------------------
# _config_escape_value()
# Escape a config value for inclusion in .env files.
# Consumes: args: value.
# Computes: escaped value string.
# Returns: prints escaped value to stdout.
# ---------------------------------------------------------------------
_config_escape_value() {
    local value="$1"
    local out="$value"
    out="${out//\\\$\{/\$\{}"
    out="${out//\\/\\\\}"
    out="${out//\"/\\\"}"
    out="${out//\$/\\\$}"
    out="${out//\`/\\\`}"
    printf "%s" "$out"
}

# ---------------------------------------------------------------------
# config_resolve_instance_id()
# Resolve a stable instance id during config creation.
# Consumes: args: base, env; deps: env_resolve_instance_id (optional).
# Computes: instance id string.
# Returns: prints instance id.
# ---------------------------------------------------------------------
config_resolve_instance_id() {
    local base="${1%/}"
    local env="${2%/}"
    if declare -F env_resolve_instance_id >/dev/null 2>&1; then
        env_resolve_instance_id "$base" "$env"
        return 0
    fi
    local seed="${base}|${env}"
    local id=""
    if command -v cksum >/dev/null 2>&1; then
        id="$(printf "%s" "$seed" | cksum | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
        id="$(printf "%s" "$seed" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        id="$(printf "%s" "$seed" | shasum -a 256 | awk '{print $1}')"
    elif command -v sha256 >/dev/null 2>&1; then
        id="$(printf "%s" "$seed" | sha256 -q 2>/dev/null)"
    elif command -v uuidgen >/dev/null 2>&1; then
        id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    else
        id="$(printf "%s" "$seed" | tr -cd '[:alnum:]' | cut -c1-16)"
    fi
    [[ -z "$id" ]] && id="unknown"
    printf "inm-%s" "$id"
}

# ---------------------------------------------------------------------
# write_config_setting()
# Write a single config key/value to INM_SELF_ENV_FILE.
# Consumes: args: key; globals: default_settings/default_inline_comments; env: INM_SELF_ENV_FILE.
# Computes: rendered config line.
# Returns: 0 after writing.
# ---------------------------------------------------------------------
write_config_setting() {
    local key="$1"
    local target_file="${2:-$INM_SELF_ENV_FILE}"
    local value="${default_settings[$key]}"
    local inline_comment=""
    if [ -n "${default_inline_comments[$key]+_}" ]; then
        inline_comment="${default_inline_comments[$key]}"
    fi
    if [[ "$key" =~ (^|_)(PASS(WORD)?|TOKEN|SECRET|KEY|CREDENTIALS)$ ]]; then
        inline_comment=""
    fi
    if [[ "$key" == "INM_RUNTIME_PHP_BIN" && -z "$value" ]]; then
        value="php"
        if [ -n "$inline_comment" ]; then
            inline_comment="${inline_comment} Auto-set to 'php' because the binary was not detected."
        else
            inline_comment="Auto-set to 'php' because the binary was not detected."
        fi
    fi
    local escaped_value
    escaped_value="$(_config_escape_value "$value")"
    if [ -n "$inline_comment" ]; then
        printf '%s="%s" # %s\n' "$key" "$escaped_value" "$inline_comment" >> "$target_file"
    else
        printf '%s="%s"\n' "$key" "$escaped_value" >> "$target_file"
    fi
}

# ---------------------------------------------------------------------
# write_config_defaults()
# Write all default settings into INM_SELF_ENV_FILE.
# Consumes: globals: default_settings/default_settings_order.
# Computes: ordered config output.
# Returns: 0 after writing.
# ---------------------------------------------------------------------
write_config_defaults() {
    local target_file="${1:-$INM_SELF_ENV_FILE}"
    local key
    # shellcheck disable=SC2154
    if declare -p default_settings_order >/dev/null 2>&1 && [ "${#default_settings_order[@]}" -gt 0 ]; then
        for key in "${default_settings_order[@]}"; do
            if [ -n "${default_settings[$key]+_}" ]; then
                write_config_setting "$key" "$target_file"
            fi
        done
    fi

    local remaining_keys=()
    for key in "${!default_settings[@]}"; do
        # shellcheck disable=SC2154
        if [[ " ${default_settings_order[*]} " != *" ${key} "* ]]; then
            remaining_keys+=("$key")
        fi
    done
    if [ "${#remaining_keys[@]}" -gt 0 ]; then
        local sorted_remaining=()
        mapfile -t sorted_remaining < <(printf '%s\n' "${remaining_keys[@]}" | sort)
        for key in "${sorted_remaining[@]}"; do
            write_config_setting "$key" "$target_file"
        done
    fi
}

# ---------------------------------------------------------------------
# persist_derived_config()
# Persist derived defaults to a config file when enabled.
# Consumes: env: INM_SELF_ENV_FILE, INM_DEFAULT_SELF_ENV_FILE, INM_PERM_CLI_ENV_MODE; globals: NAMED_ARGS.
# Computes: config file creation and defaults write.
# Returns: 0 on success, non-zero on failure.
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
    if ! grep -q "^INM_SELF_INSTANCE_ID=" "$INM_SELF_ENV_FILE"; then
        local inst_id
        inst_id="$(config_resolve_instance_id "${INM_PATH_BASE_DIR:-}" "${INM_PATH_APP_ENV_FILE:-}")"
        if ! grep -q "^INM_SELF_INSTANCE_ID=" "$INM_SELF_ENV_FILE"; then
            echo "INM_SELF_INSTANCE_ID=\"${inst_id}\"" >> "$INM_SELF_ENV_FILE"
        fi
    fi
    if ! grep -q "^INM_SELF_CLI_COMPAT_MODE=" "$INM_SELF_ENV_FILE"; then
        echo "INM_SELF_CLI_COMPAT_MODE=\"ultron\"" >> "$INM_SELF_ENV_FILE"
    fi

    local cli_env_mode="${default_settings[INM_PERM_CLI_ENV_MODE]:-${INM_PERM_CLI_ENV_MODE:-600}}"
    chmod "$cli_env_mode" "$INM_SELF_ENV_FILE" 2>/dev/null
    log ok "[PDC] Config persisted successfully"
    INM_CONFIG_CREATED_THIS_RUN=true
    warn_cli_config_owner_mismatch "$INM_SELF_ENV_FILE"

    return 0
}

# ---------------------------------------------------------------------
# _config_read_value()
# Read a key value from a config file without eval.
# Consumes: args: key, file.
# Computes: raw value from file.
# Returns: prints value or empty string.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# config_expected_owner()
# Determine expected owner/group from CLI config values.
# Consumes: args: config_file; deps: _config_read_value.
# Computes: expected owner:group string.
# Returns: prints owner:group or empty string.
# ---------------------------------------------------------------------
config_expected_owner() {
    local config_file="$1"
    local user group
    user="$(_config_read_value "INM_EXEC_USER" "$config_file")"
    if [[ -z "$user" ]]; then
        return 0
    fi
    group="$(_config_read_value "INM_EXEC_GROUP" "$config_file")"
    if [[ -z "$group" ]]; then
        group="$(id -gn "$user" 2>/dev/null || true)"
        [[ -z "$group" ]] && group="$user"
    fi
    printf "%s:%s" "$user" "$group"
}

# ---------------------------------------------------------------------
# warn_cli_config_owner_mismatch()
# Warn when CLI config file owner differs from expected.
# Consumes: args: config_file; deps: config_expected_owner/_fs_get_owner.
# Computes: ownership mismatch message.
# Returns: 0 after check.
# ---------------------------------------------------------------------
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
    current="$(_fs_get_owner "$config_file")"
    if [[ -n "$current" && "$current" != "$expected" ]]; then
        log warn "[CFG] Config owner mismatch: $config_file (owner=$current, expected=$expected). Consider: sudo chown $expected \"$config_file\""
    fi
}

# ---------------------------------------------------------------------
# create_own_config()
# Interactive wizard to create or recreate CLI config.
# Consumes: env: INM_SELF_ENV_FILE/INM_DEFAULT_SELF_ENV_FILE; globals: NAMED_ARGS/prompt_order.
# Computes: config file creation and prompts.
# Returns: 0 on success, exits on fatal errors.
# ---------------------------------------------------------------------
create_own_config() {
    log debug "[COC] init."
    INM_SELF_ENV_FILE="${NAMED_ARGS[target_file]:-${INM_SELF_ENV_FILE:-$INM_DEFAULT_SELF_ENV_FILE}}"

    local -A named_args_canon=()
    local key
    for key in "${!NAMED_ARGS[@]}"; do
        [[ "$key" == INM_* ]] || continue
        named_args_canon["$key"]="${NAMED_ARGS[$key]}"
    done

    # shellcheck disable=SC2154
    if [ -f "$INM_SELF_ENV_FILE" ] && [ "$force_update" != true ]; then
        log debug "[COC] Config file '$INM_SELF_ENV_FILE' already exists. Use create_config --force to recreate."
        return 0
    fi
    log info "[COC] Creating configuration in: $INM_SELF_ENV_FILE"
    echo -e "\n${GREEN}========== Install Wizard ==========${NC}\n"

    local non_interactive=true
    # shellcheck disable=SC2154
    for key in "${prompt_order[@]}"; do
        if [ -z "${named_args_canon[$key]+_}" ]; then
            non_interactive=false
            break
        fi
    done

    if [ "$non_interactive" = false ]; then
        log note "Just press [ENTER] to accept default values."
        for key in "${prompt_order[@]}"; do
            local defval="${default_settings[$key]}"
            local prompt_text="${prompt_texts[$key]:-"Provide value for $key:"}"
            local input=""
            input="$(prompt_var "$key" "$defval" "$prompt_text" false 120)" || return 1
            # shellcheck disable=SC2004
            default_settings[$key]="${input:-$defval}"
        done
    else
        log info "[COC] All values provided via --key=value args. Skipping interactive prompt."
        for key in "${prompt_order[@]}"; do
            # shellcheck disable=SC2004
            default_settings[$key]="${named_args_canon[$key]:-${default_settings[$key]}}"
        done
    fi

    for key in "${!default_settings[@]}"; do
        if [ -n "${named_args_canon[$key]+_}" ]; then
            # shellcheck disable=SC2004
            default_settings[$key]="${named_args_canon[$key]}"
        fi
    done

    local target_dir
    target_dir="$(dirname "$INM_SELF_ENV_FILE")"
    local enforced_user="${default_settings[INM_EXEC_USER]:-}"
    local enforced_group="${default_settings[INM_EXEC_GROUP]:-}"
    local current_user=""
    current_user="$(id -un 2>/dev/null || true)"
    if [[ -z "$enforced_user" ]]; then
        enforced_user="$current_user"
    fi
    if [[ -z "$enforced_group" ]]; then
        enforced_group="$(id -gn "$enforced_user" 2>/dev/null || true)"
    fi
    [[ -z "$enforced_group" ]] && enforced_group="$enforced_user"

    local need_priv=false
    local use_sudo=false
    if [[ -n "$enforced_user" && "$enforced_user" != "$current_user" ]]; then
        need_priv=true
        if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
            use_sudo=false
        elif command -v sudo >/dev/null 2>&1; then
            if ! sudo -n true 2>/dev/null; then
                if ! prompt_confirm "COC_SUDO" "no" "Create config as ${enforced_user} via sudo? [y/N]" false 60; then
                    log err "[COC] Config must be created as ${enforced_user}. Run as that user or with sudo."
                    exit 1
                fi
            fi
            use_sudo=true
        else
            log err "[COC] Config must be created as ${enforced_user}. Run as that user or with sudo."
            exit 1
        fi
    fi

    if ! mkdir -p "$target_dir" >/dev/null 2>&1; then
        if [[ "$use_sudo" == true ]]; then
            sudo mkdir -p "$target_dir" >/dev/null 2>&1 || {
                log err "[COC] Could not create directory '$target_dir'"
                exit 1
            }
        else
            log err "[COC] Could not create directory '$target_dir'"
            exit 1
        fi
    fi

    if [ -f "$INM_SELF_ENV_FILE" ]; then
        if [[ "$use_sudo" == true ]]; then
            sudo cp -f "$INM_SELF_ENV_FILE" "$INM_SELF_ENV_FILE.bak.$(date +%s)" >/dev/null 2>&1 || {
                log warn "[COC] Could not create backup of existing config."
            }
            sudo rm -f "$INM_SELF_ENV_FILE" >/dev/null 2>&1 || {
                log err "[COC] Could not remove existing config file '$INM_SELF_ENV_FILE'. Aborting."
                exit 1
            }
        else
            cp -f "$INM_SELF_ENV_FILE" "$INM_SELF_ENV_FILE.bak.$(date +%s)" >/dev/null 2>&1 || {
                log warn "[COC] Could not create backup of existing config."
            }
            rm -f "$INM_SELF_ENV_FILE" >/dev/null 2>&1 || {
                log err "[COC] Could not remove existing config file '$INM_SELF_ENV_FILE'. Aborting."
                exit 1
            }
        fi
    fi

    local tmp_file
    tmp_file="$(mktemp)" || {
        log err "[COC] Error: Could not create temporary config file. Aborting."
        exit 1
    }

    write_config_defaults "$tmp_file"
    for key in "${!named_args_canon[@]}"; do
        if [ -z "${default_settings[$key]+_}" ]; then
            echo "$key=\"${named_args_canon[$key]}\"" >> "$tmp_file"
        fi
    done
    if ! grep -q "^INM_SELF_INSTANCE_ID=" "$tmp_file"; then
        local inst_id
        inst_id="$(config_resolve_instance_id "${INM_PATH_BASE_DIR:-}" "${INM_PATH_APP_ENV_FILE:-}")"
        if ! grep -q "^INM_SELF_INSTANCE_ID=" "$tmp_file"; then
            echo "INM_SELF_INSTANCE_ID=\"${inst_id}\"" >> "$tmp_file"
        fi
    fi
    if ! grep -q "^INM_SELF_CLI_COMPAT_MODE=" "$tmp_file"; then
        echo "INM_SELF_CLI_COMPAT_MODE=\"ultron\"" >> "$tmp_file"
    fi

    if [[ "$use_sudo" == true ]]; then
        sudo mv "$tmp_file" "$INM_SELF_ENV_FILE" >/dev/null 2>&1 || {
            rm -f "$tmp_file" >/dev/null 2>&1 || true
            log err "[COC] Error: Could not write to '$INM_SELF_ENV_FILE'. Aborting."
            exit 1
        }
        sudo chown "${enforced_user}:${enforced_group}" "$INM_SELF_ENV_FILE" 2>/dev/null || true
    else
        mv "$tmp_file" "$INM_SELF_ENV_FILE" >/dev/null 2>&1 || {
            rm -f "$tmp_file" >/dev/null 2>&1 || true
            log err "[COC] Error: Could not write to '$INM_SELF_ENV_FILE'. Aborting."
            exit 1
        }
        if [[ "$need_priv" == true ]]; then
            chown "${enforced_user}:${enforced_group}" "$INM_SELF_ENV_FILE" 2>/dev/null || true
        fi
    fi

    local cli_env_mode="${default_settings[INM_PERM_CLI_ENV_MODE]:-${INM_PERM_CLI_ENV_MODE:-600}}"
    if [[ "$use_sudo" == true ]]; then
        sudo chmod "$cli_env_mode" "$INM_SELF_ENV_FILE" 2>/dev/null || true
    else
        chmod "$cli_env_mode" "$INM_SELF_ENV_FILE" 2>/dev/null || true
    fi
    log ok "$INM_SELF_ENV_FILE has been created and configured."
    INM_CONFIG_CREATED_THIS_RUN=true

    load_env_file_raw "$INM_SELF_ENV_FILE"
    warn_cli_config_owner_mismatch "$INM_SELF_ENV_FILE"

    local history_file=""
    if [[ -n "${INM_LOG_OPS_FILE:-}" ]]; then
        if declare -F path_expand_no_eval >/dev/null 2>&1; then
            history_file="$(path_expand_no_eval "$INM_LOG_OPS_FILE")"
        else
            history_file="$INM_LOG_OPS_FILE"
        fi
        if [[ "$history_file" != /* && -n "${INM_PATH_BASE_DIR:-}" ]]; then
            history_file="${INM_PATH_BASE_DIR%/}/${history_file#/}"
        fi
    elif [[ -n "${INM_PATH_BASE_DIR:-}" ]]; then
        history_file="${INM_PATH_BASE_DIR%/}/.inmanage/history.log"
    fi
    if [[ -n "$history_file" ]]; then
        local history_dir
        history_dir="$(dirname "$history_file")"
        if [[ -d "$history_dir" ]]; then
            local expected_owner="${enforced_user}:${enforced_group}"
            if [[ -e "$history_file" ]]; then
                local current_owner
                current_owner="$(_fs_get_owner "$history_file")"
                if [[ -n "$current_owner" && -n "$expected_owner" && "$current_owner" != "$expected_owner" ]]; then
                    if [[ -w "$history_dir" ]]; then
                        local ts
                        ts="$(date +%s)"
                        mv -f "$history_file" "${history_file}.bak.${ts}" 2>/dev/null || true
                    fi
                fi
            fi
            if [[ ! -e "$history_file" && -w "$history_dir" ]]; then
                : > "$history_file" 2>/dev/null || true
                chmod 600 "$history_file" 2>/dev/null || true
            fi
            if [[ "$use_sudo" == true && -n "$enforced_user" && -e "$history_file" ]]; then
                sudo -n -u "$enforced_user" sh -c '
history_file="$1"
if [ -f "$history_file" ]; then
  chmod 600 "$history_file" 2>/dev/null || true
fi
' sh "$history_file" >/dev/null 2>&1 || true
            elif [[ -n "$enforced_user" && -e "$history_file" ]]; then
                enforce_ownership "$history_file" "$history_dir" || true
            fi
        fi
    fi

    if [ -z "$INM_PATH_BASE_DIR" ]; then
        log err "[COC] 'INM_PATH_BASE_DIR' is empty. Aborting."
        exit 1
    fi

    INM_ENV_EXAMPLE_FILE="${INM_PATH_BASE_DIR%/}/.inmanage/.env.example"
    log debug "[COC] INM_ENV_EXAMPLE_FILE set to $INM_ENV_EXAMPLE_FILE"

    log info "[COC] Downloading .env.example for provisioning"
    local env_example_contents=""
    local -a auth_args=()
    gh_auth_args auth_args
    http_fetch_with_args "https://raw.githubusercontent.com/invoiceninja/invoiceninja/v5-stable/.env.example" \
        env_example_contents false -L "${auth_args[@]}" || {
            log err "[COC] Failed to download .env.example"
            exit 1
        }
    printf "%s" "$env_example_contents" > "$INM_ENV_EXAMPLE_FILE"

    if [ -f "$INM_ENV_EXAMPLE_FILE" ]; then
        if ! grep -q '^DB_ELEVATED_USERNAME=' "$INM_ENV_EXAMPLE_FILE" 2>/dev/null; then
            local sed_expr='/^DB_PORT=/a DB_ELEVATED_USERNAME=\nDB_ELEVATED_PASSWORD='
            if ! sed -i '' -e "$sed_expr" "$INM_ENV_EXAMPLE_FILE" 2>/dev/null; then
                sed -i -e "$sed_expr" "$INM_ENV_EXAMPLE_FILE" 2>/dev/null || {
                    log debug "[COC] Failed to update DB_ELEVATED_* entries in $INM_ENV_EXAMPLE_FILE"
                }
            fi
        fi
    fi

    check_provision_file
}

# ---------------------------------------------------------------------
# spawn_cli_config()
# Create a CLI config file from defaults and --INM_* overrides.
# Consumes: NAMED_ARGS (INM_* keys, config, force); defaults from core config.
# Computes: config file on disk.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
spawn_cli_config() {
    local target="${NAMED_ARGS[config]:-${INM_SELF_ENV_FILE:-$INM_DEFAULT_SELF_ENV_FILE}}"
    local force="${NAMED_ARGS[force]:-false}"
    local target_dir
    target_dir="$(dirname "$target")"

    if [[ -f "$target" && "$force" != true ]]; then
        log err "[CFG] Config already exists: $target (use --force to overwrite)."
        return 1
    fi
    mkdir -p "$target_dir" 2>/dev/null || {
        log err "[CFG] Could not create config target directory: $target_dir"
        return 1
    }
    : > "$target" 2>/dev/null || {
        log err "[CFG] Failed to create config file: $target"
        return 1
    }

    local prev_env_file="${INM_SELF_ENV_FILE:-}"
    INM_SELF_ENV_FILE="$target"

    local -A saved_defaults=()
    local -A extra_values=()
    local key
    for key in "${!NAMED_ARGS[@]}"; do
        [[ "$key" == INM_* ]] || continue
        if [[ -n "${default_settings[$key]+_}" ]]; then
            saved_defaults["$key"]="${default_settings[$key]}"
            default_settings["$key"]="${NAMED_ARGS[$key]}"
        else
            extra_values["$key"]="${NAMED_ARGS[$key]}"
        fi
    done

    write_config_defaults
    if ! grep -q "^INM_SELF_INSTANCE_ID=" "$INM_SELF_ENV_FILE"; then
        local inst_id
        inst_id="$(config_resolve_instance_id "${INM_PATH_BASE_DIR:-}" "${INM_PATH_APP_ENV_FILE:-}")"
        if ! grep -q "^INM_SELF_INSTANCE_ID=" "$INM_SELF_ENV_FILE"; then
            echo "INM_SELF_INSTANCE_ID=\"${inst_id}\"" >> "$INM_SELF_ENV_FILE"
        fi
    fi
    if ! grep -q "^INM_SELF_CLI_COMPAT_MODE=" "$INM_SELF_ENV_FILE"; then
        echo "INM_SELF_CLI_COMPAT_MODE=\"ultron\"" >> "$INM_SELF_ENV_FILE"
    fi

    for key in "${!extra_values[@]}"; do
        local escaped
        escaped="$(_config_escape_value "${extra_values[$key]}")"
        printf '%s="%s"\n' "$key" "$escaped" >> "$INM_SELF_ENV_FILE"
    done

    for key in "${!saved_defaults[@]}"; do
        default_settings["$key"]="${saved_defaults[$key]}"
    done

    local cli_env_mode="${default_settings[INM_PERM_CLI_ENV_MODE]:-${INM_PERM_CLI_ENV_MODE:-600}}"
    chmod "$cli_env_mode" "$INM_SELF_ENV_FILE" 2>/dev/null
    log ok "[CFG] Config written: $INM_SELF_ENV_FILE"
    INM_CONFIG_CREATED_THIS_RUN=true
    warn_cli_config_owner_mismatch "$INM_SELF_ENV_FILE"
    INM_SELF_ENV_FILE="$prev_env_file"
    return 0
}
