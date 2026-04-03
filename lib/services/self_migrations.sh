#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_SELF_MIGRATIONS_LOADED:-} ]] && return
__SERVICE_SELF_MIGRATIONS_LOADED=1

# ---------------------------------------------------------------------
# Migration key/value plan (ordered).
# Entry format: <state>|<script>|<function>
# - <state>: value written to SELF_MIGRATIONS_KEY after the migration completes
# - <script>: file in lib/self_migrations/ to source
# - <function>: entrypoint in that script
# To add a new migration, append to SELF_MIGRATIONS_PLAN in the order it must run.
SELF_MIGRATIONS_KEY="INM_SELF_CLI_COMPAT_MODE"
SELF_MIGRATIONS_PLAN=(
    "ultron|001_main_branch_keys.sh|migration_001_main_branch_keys"
    "ultron-main|002_checkout_main_branch.sh|migration_002_checkout_main_branch"
)

_self_migrations_read_value() {
    local config_file="$1"
    local key="$2"
    local val=""
    if declare -F read_env_value_safe >/dev/null 2>&1; then
        val="$(read_env_value_safe "$config_file" "$key" 2>/dev/null)"
    else
        local line=""
        line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$config_file" 2>/dev/null | tail -n1)"
        val="${line#*=}"
        val="${val%%#*}"
        val="$(printf "%s" "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        val="${val%\"}"
        val="${val#\"}"
    fi
    printf "%s" "$val"
}

_self_migrations_plan_index() {
    local value="$1"
    local i entry state
    for i in "${!SELF_MIGRATIONS_PLAN[@]}"; do
        entry="${SELF_MIGRATIONS_PLAN[$i]}"
        state="${entry%%|*}"
        if [[ "$state" == "$value" ]]; then
            printf "%s" "$i"
            return 0
        fi
    done
    printf "%s" "-1"
    return 0
}

# ---------------------------------------------------------------------
# self_migrations_legacy_root()
# Resolve legacy project root (typically .inmanage within base dir).
# Returns: prints path or empty on failure.
# ---------------------------------------------------------------------
self_migrations_legacy_root() {
    local base_dir="${INM_PATH_BASE_DIR:-}"
    [[ -z "$base_dir" ]] && return 1
    if declare -F path_expand_no_eval >/dev/null 2>&1; then
        base_dir="$(path_expand_no_eval "$base_dir")"
    fi
    base_dir="${base_dir%/}"
    local config_root="${INM_CONFIG_ROOT:-.inmanage}"
    local legacy_root="$config_root"
    if [[ "$legacy_root" != /* ]]; then
        legacy_root="${base_dir%/}/${legacy_root#/}"
    fi
    printf "%s" "$legacy_root"
}

_self_migrations_legacy_symlink() {
    local base_dir="$1"
    local legacy_root="$2"
    local link_path="${base_dir%/}/inmanage.sh"
    [[ -L "$link_path" ]] || return 1
    local target=""
    target="$(readlink "$link_path" 2>/dev/null || true)"
    if [[ -z "$target" ]]; then
        return 1
    fi
    if [[ "$target" == ".inmanage/inmanage.sh" || "$target" == "${legacy_root}/inmanage.sh" || "$target" == */.inmanage/inmanage.sh ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# self_migrations_legacy_detected()
# Check if a legacy local install still exists in the project.
# Returns: 0 if legacy repo or symlink found, 1 otherwise.
# ---------------------------------------------------------------------
self_migrations_legacy_detected() {
    local base_dir="${INM_PATH_BASE_DIR:-}"
    [[ -z "$base_dir" ]] && return 1
    if declare -F path_expand_no_eval >/dev/null 2>&1; then
        base_dir="$(path_expand_no_eval "$base_dir")"
    fi
    base_dir="${base_dir%/}"
    local legacy_root
    legacy_root="$(self_migrations_legacy_root)" || return 1
    if [[ -d "$legacy_root/.git" || -f "$legacy_root/inmanage.sh" || -d "$legacy_root/lib" ]]; then
        return 0
    fi
    if _self_migrations_legacy_symlink "$base_dir" "$legacy_root"; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# self_migrations_legacy_cleanup()
# Remove legacy repo content and legacy project symlink.
# Consumes: env: INM_PATH_BASE_DIR; deps: legacy_cleanup_repo/legacy_backup_path.
# ---------------------------------------------------------------------
self_migrations_legacy_cleanup() {
    local base_dir="${INM_PATH_BASE_DIR:-}"
    [[ -z "$base_dir" ]] && return 0
    if declare -F path_expand_no_eval >/dev/null 2>&1; then
        base_dir="$(path_expand_no_eval "$base_dir")"
    fi
    base_dir="${base_dir%/}"
    local legacy_root
    legacy_root="$(self_migrations_legacy_root)" || return 0

    if declare -F legacy_cleanup_repo >/dev/null 2>&1; then
        legacy_cleanup_repo "$legacy_root" "$base_dir"
    fi

    local link_path="${base_dir%/}/inmanage.sh"
    if _self_migrations_legacy_symlink "$base_dir" "$legacy_root"; then
        if declare -F legacy_backup_path >/dev/null 2>&1; then
            legacy_backup_path "$link_path" "$base_dir"
        else
            rm -f "$link_path" 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------
# self_migrations_prompt_legacy_cleanup()
# Prompt to remove legacy local install after config migration.
# ---------------------------------------------------------------------
self_migrations_prompt_legacy_cleanup() {
    if ! self_migrations_legacy_detected; then
        return 0
    fi
    local interactive=false
    if declare -F legacy_is_interactive >/dev/null 2>&1; then
        if legacy_is_interactive; then
            interactive=true
        fi
    elif [[ -t 0 && -t 1 ]]; then
        interactive=true
    fi
    if [[ "$interactive" != true ]]; then
        return 0
    fi
    if ! declare -F prompt_confirm >/dev/null 2>&1; then
        return 0
    fi
    if prompt_confirm "SELF_MIG_LEGACY_CLEANUP" "no" \
        "Legacy local install detected (.inmanage repo / inmanage.sh). Remove it now? (yes/no):" \
        false 120; then
        self_migrations_legacy_cleanup
    else
        log info "[SELF_MIG] You can remove it later with: inm self update --legacy-migration=force"
    fi
}

# ---------------------------------------------------------------------
# self_migrations_run_if_needed()
# Run CLI config migrations based on the configured migration state.
# Consumes: args: config_file; env: INM_SELF_ENV_FILE; deps: env_set/load_env_file_raw.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
self_migrations_run_if_needed() {
    local config_file="${1:-$INM_SELF_ENV_FILE}"
    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        return 0
    fi

    local prev_env_file="${INM_SELF_ENV_FILE:-}"
    INM_SELF_ENV_FILE="$config_file"

    if [[ -z "${SELF_MIGRATIONS_KEY:-}" || "${#SELF_MIGRATIONS_PLAN[@]}" -eq 0 ]]; then
        INM_SELF_ENV_FILE="$prev_env_file"
        return 0
    fi

    local current_value=""
    current_value="$(_self_migrations_read_value "$config_file" "$SELF_MIGRATIONS_KEY")"
    local current_index
    current_index="$(_self_migrations_plan_index "$current_value")"
    if [[ -n "$current_value" && "$current_index" == "-1" ]]; then
        log debug "[SELF_MIG] Unknown ${SELF_MIGRATIONS_KEY} value '${current_value}', running full migration chain."
        current_index="-1"
    fi

    local start_index=$((current_index + 1))
    if [[ "$start_index" -ge "${#SELF_MIGRATIONS_PLAN[@]}" ]]; then
        INM_SELF_ENV_FILE="$prev_env_file"
        return 0
    fi

    log debug "[SELF_MIG] Running CLI config migrations from index ${start_index}."

    local mig_dir="${LIB_DIR}/self_migrations"
    local i entry target_value script_name func_name script_path
    local ran_migrations=false
    for ((i=start_index; i<${#SELF_MIGRATIONS_PLAN[@]}; i++)); do
        entry="${SELF_MIGRATIONS_PLAN[$i]}"
        target_value="${entry%%|*}"
        script_name="${entry#*|}"
        script_name="${script_name%%|*}"
        func_name="${entry##*|}"

        script_path="${mig_dir}/${script_name}"
        if [[ ! -f "$script_path" ]]; then
            log err "[SELF_MIG] Missing migration script: ${script_path}"
            INM_SELF_ENV_FILE="$prev_env_file"
            return 1
        fi

        # shellcheck source=/dev/null
        source "$script_path"
        if ! declare -F "$func_name" >/dev/null 2>&1; then
            log err "[SELF_MIG] Migration entrypoint not found: ${func_name}"
            INM_SELF_ENV_FILE="$prev_env_file"
            return 1
        fi

        "$func_name" "$config_file" || {
            INM_SELF_ENV_FILE="$prev_env_file"
            return 1
        }
        ran_migrations=true

        if env_set cli "${SELF_MIGRATIONS_KEY}=${target_value}" >/dev/null 2>&1; then
            :
        else
            export "${SELF_MIGRATIONS_KEY}=${target_value}"
        fi
        current_value="$target_value"
    done

    load_env_file_raw "$config_file" || true
    log debug "[SELF_MIG] CLI config migration completed (state: ${current_value:-<unknown>})."
    if [[ "$ran_migrations" == true ]]; then
        if declare -F config_sort_cli_env >/dev/null 2>&1; then
            config_sort_cli_env "$config_file" false
        fi
        self_migrations_prompt_legacy_cleanup
    fi

    INM_SELF_ENV_FILE="$prev_env_file"
    return 0
}
