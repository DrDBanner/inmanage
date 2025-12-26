#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_SELF_INSTALL_LOADED:-} ]] && return
__SERVICE_SELF_INSTALL_LOADED=1

# ---------------------------------------------------------------------
# install_self()
# Handles self-install (global/local/project) and symlinks.
# ---------------------------------------------------------------------
install_self() {
  if [[ "${DRY_RUN:-false}" == true ]]; then
    log info "[DRY-RUN] Skipping self install."
    return 0
  fi
  log debug "[SELF] Checking CLI installation …"

  local default_bin="/usr/local/bin"
  local local_bin="$HOME/.local/bin"
  local source_script
  source_script="$(realpath "$0")"

  local install_dir="${NAMED_ARGS[target_dir]:-${NAMED_ARGS[--target-dir]:-}}"
  local install_mode="${NAMED_ARGS[install_mode]:-${NAMED_ARGS[--install-mode]:-}}"
  local run_user
  run_user="${INM_ENFORCED_USER:-$(whoami)}"

  # Ask early which user should run inmanage
  run_user="$(prompt_var "RUN_AS_USER" "$run_user" "Which user should run inmanage commands? (cron/artisan will use this)")"
  if ! id -u "$run_user" >/dev/null 2>&1; then
      log warn "[SELF] User '$run_user' does not exist on this system. Using current user: $(whoami)"
      run_user="$(whoami)"
  fi
  log info "[SELF] Will target run-user: $run_user"

  # Derive a base_dir for project mode defaults
  local base_dir="${INM_BASE_DIRECTORY:-$PWD}"
  if declare -F ensure_trailing_slash >/dev/null; then
      base_dir="$(ensure_trailing_slash "$base_dir")"
  fi

  if [[ -z "$install_mode" ]]; then
    echo
    echo "Select installation mode:"
    echo "  [1] Full Install     – system-wide (requires sudo/root)"
    echo "  [2] Local Install    – user context (~/.local/bin)"
    echo "  [3] Project Install  – once per project (least convenient)"
    echo
    prompt_var "INSTALL_MODE" "Mode (1/2/3)" "2"
    # shellcheck disable=SC2153
    install_mode="$INSTALL_MODE"
  fi

  if [[ -z "$install_dir" ]]; then
    case "$install_mode" in
      1) install_dir="/usr/local/share/inmanage" ;;
      2) install_dir="$HOME/.inmanage_app" ;;
      3) install_dir="${base_dir%/}/.inmanage_app" ;;
      *) log err "[SELF] Invalid mode: $install_mode" ; return 1 ;;
    esac
  fi

  # Allow override of the computed install directory per mode
  install_dir="$(prompt_var "INSTALL_DIR" "$install_dir" "Install directory for the inmanage app? (ENTER for default)")"
  INM_SELF_INSTALL_DIR="$install_dir"

  if [[ "$(realpath "$install_dir")" == "$(realpath "$(dirname "$source_script")")" ]]; then
      log err "[SELF] Source and target install directory are the same. Choose a different target."
      return 1
  fi

  if [[ "$install_mode" == "3" && -f "$(pwd)/.inmanage/inmanage.sh" && "$install_dir" != "$(pwd)/.inmanage" ]]; then
      log warn "[SELF] Legacy project install detected at .inmanage/; new target is $install_dir"
      log warn "[SELF] Consider migrating after this install if you want to keep config/data separate."
  fi

  log debug "[SELF] Installing to: $install_dir"
  mkdir -p "$install_dir" || { log err "[SELF] Cannot create $install_dir"; return 1; }

  safe_move_or_copy_and_clean "$(dirname "$source_script")" "$install_dir" copy || {
    log err "[SELF] Failed to copy files"; return 1;
  }

  local bin_source="$install_dir/inmanage.sh"
  INM_SELF_INSTALL_SCRIPT="$bin_source"
  INM_SELF_INSTALL_MODE="$install_mode"
  local targets=("inmanage" "inm")

  case "$install_mode" in
    1)
      log info "[SELF] Global install selected; ensure enforced user '$run_user' exists and has needed perms for cron/artisan."
      for name in "${targets[@]}"; do
        if [[ -w "$default_bin" ]]; then
          ln -sf "$bin_source" "$default_bin/$name"
        elif command -v sudo &>/dev/null; then
          prompt_var "ROOTPW" "Root password needed to install system-wide" "" silent=true timeout=15 || return 1
          echo "$ROOTPW" | sudo -S ln -sf "$bin_source" "$default_bin/$name"
        else
          log err "[SELF] Cannot write to $default_bin and sudo not available"
          return 1
        fi
      done
      log ok "[SELF] Installed globally in $default_bin"
      ;;
    2)
      if [[ "$run_user" != "$(whoami)" ]]; then
          log warn "[SELF] User-mode install uses current user $(whoami); enforced run-user '$run_user' must still exist for cron/artisan."
      fi
      mkdir -p "$local_bin"
      for name in "${targets[@]}"; do
        ln -sf "$bin_source" "$local_bin/$name"
      done
      log ok "[SELF] Installed locally in $local_bin"
      if [[ ":$PATH:" != *":$local_bin:"* ]]; then
        log warn "[SELF] Add '$local_bin' to your PATH."
      fi
      ;;
    3)
      log info "[INSTALL] Mode: Project Install (only for this project)"

      local project_root="${base_dir%/}"
      if [[ ! -d "$project_root" ]]; then
          log info "[INSTALL] Creating project root: $project_root"
          mkdir -p "$project_root" || {
              log err "[INSTALL] Failed to create project root: $project_root"
              exit 1
          }
      fi

      local app_dir="$install_dir"
      local source_path
      source_path="$(realpath "$0")"

      mkdir -p "$app_dir" || {
      log err "[INSTALL] Could not create project app directory: $app_dir"
          exit 1
      }

      safe_move_or_copy_and_clean "$(dirname "$source_path")" "$app_dir" || {
          log err "[INSTALL] Could not deploy to project directory."
          exit 1
      }

      local app_source="$app_dir/inmanage.sh"
      local legacy_app_dir="${project_root}/.inmanage"

      # Symlinks in project root (update legacy if pointing to .inmanage)
      for name in "inmanage" "inm"; do
          local link="${project_root}/${name}"
          if [[ -L "$link" ]]; then
              local target
              target="$(readlink "$link")"
              if [[ "$target" == ".inmanage/inmanage.sh" || "$target" == "$legacy_app_dir/inmanage.sh" ]]; then
                  log info "[INSTALL] Updating legacy symlink $link -> $app_source"
              fi
          fi
          ln -sf "$app_source" "$link" || log err "[INSTALL] Failed to create symlink: $link"
      done

      log ok "[INSTALL] Project install completed in: $app_dir"
      log info "[INSTALL] Run './inmanage core install' (or '--provision') from project root."
      log info "[INSTALL] Config stays in ${project_root}/.inmanage/.env.inmanage (keep it outside the app)."

      echo
      log info "Tip: You can install globally anytime via 'inmanage self install --install-mode=1'"

      echo
      prompt_var "CREATE_CONFIG_NOW" "Would you like to create a project config now? [y/N]" "n"
      if [[ "${CREATE_CONFIG_NOW,,}" =~ ^(y|yes)$ ]]; then
          if command -v create_project_config &>/dev/null; then
              create_project_config "$app_dir"
          else
              log warn "[INSTALL] Function 'create_project_config' not found. Skipping config creation."
          fi
      fi

      return 0
      ;;
  esac

  echo
  prompt_var "CREATE_CONFIG" "Create project config now? [y/N]" "n"
  if [[ "$CREATE_CONFIG" =~ ^[YyJj]$ ]]; then
    create_own_config
  else
    log info "[SELF] Tip: Run 'inmanage create_config' to get started."
  fi
}

# ---------------------------------------------------------------------
# self_update()
# Updates the CLI in-place (git pull) if installed from a git checkout.
# ---------------------------------------------------------------------
self_update() {
  local root
  root="$(cd "$(dirname "$0")" && pwd)"
  if [[ ! -d "$root/.git" ]]; then
    log warn "[SELF] No git metadata found at $root; re-run installer to update."
    return 1
  fi
  if [[ "${DRY_RUN:-false}" == true ]]; then
    log info "[DRY-RUN] Would run git pull in $root"
    return 0
  fi
  log info "[SELF] Updating CLI in $root (git pull)"
  if git -C "$root" pull --ff-only; then
    log ok "[SELF] Update completed."
  else
    log err "[SELF] git pull failed; resolve manually."
    return 1
  fi
}

# ---------------------------------------------------------------------
# self_switch_mode()
# Reinstall CLI in a different mode; optionally cleans old symlinks/dir.
# ---------------------------------------------------------------------
self_switch_mode() {
  local old_root
  old_root="$(cd "$(dirname "$0")" && pwd)"
  local force_clean="${NAMED_ARGS[force_clean]:-${NAMED_ARGS[--force-clean-old]:-false}}"

  log info "[SELF] Switching mode; current install: $old_root"
  # Reuse install_self with provided args (may prompt if none given)
  if [[ "${DRY_RUN:-false}" == true ]]; then
    log info "[DRY-RUN] Would switch mode (call install_self) and clean old symlinks/dir=${force_clean}"
    return 0
  fi

  install_self || {
    log err "[SELF] Mode switch failed during install."
    return 1
  }

  # Clean old symlinks that point to previous root
  local links=("/usr/local/bin/inmanage" "/usr/local/bin/inm" "$HOME/.local/bin/inmanage" "$HOME/.local/bin/inm" "$(pwd)/inmanage" "$(pwd)/inm")
  for link in "${links[@]}"; do
    if [[ -L "$link" ]]; then
      local target
      target="$(readlink "$link")"
      if [[ "$target" == "$old_root/inmanage.sh" || "$target" == "$old_root/./inmanage.sh" ]]; then
        log info "[SELF] Removing old symlink: $link"
        rm -f "$link"
      fi
    fi
  done

  if [[ "$force_clean" == true ]]; then
    log info "[SELF] Removing old install at $old_root"
    rm -rf "$old_root"
  else
    log info "[SELF] Old install left at $old_root (use --force-clean-old to remove)."
  fi
}

# ---------------------------------------------------------------------
# self_uninstall()
# Removes symlinks pointing to this install and optionally deletes it.
# ---------------------------------------------------------------------
self_uninstall() {
  local root
  root="$(cd "$(dirname "$0")" && pwd)"
  local force_delete="${NAMED_ARGS[force]:-${NAMED_ARGS[--force]:-false}}"

  if [[ "${DRY_RUN:-false}" == true ]]; then
    log info "[DRY-RUN] Would uninstall CLI at $root (force delete=$force_delete)"
    return 0
  fi

  log info "[SELF] Uninstalling CLI from $root"
  local links=("/usr/local/bin/inmanage" "/usr/local/bin/inm" "$HOME/.local/bin/inmanage" "$HOME/.local/bin/inm" "$(pwd)/inmanage" "$(pwd)/inm")
  for link in "${links[@]}"; do
    if [[ -L "$link" ]]; then
      local target
      target="$(readlink "$link")"
      if [[ "$target" == "$root/inmanage.sh" || "$target" == "$root/./inmanage.sh" ]]; then
        log info "[SELF] Removing symlink: $link"
        rm -f "$link"
      fi
    fi
  done

  if [[ "$force_delete" == true ]]; then
    log info "[SELF] Removing install directory: $root"
    rm -rf "$root"
  else
    log info "[SELF] Install directory left at $root (use --force to delete)."
  fi

  log ok "[SELF] Uninstall steps completed."
}

# ---------------------------------------------------------------------
# Legacy migration helpers
# ---------------------------------------------------------------------
legacy_is_interactive() {
  [[ -t 0 && -t 1 ]]
}

legacy_resolve_path() {
  local target="$1"
  if declare -F resolve_script_path >/dev/null 2>&1; then
    resolve_script_path "$target" 2>/dev/null && return
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null && return
  fi
  printf "%s" "$target"
}

legacy_backup_dir() {
  local base_dir="$1"
  local legacy_dir="${INM_CONFIG_ROOT:-.inmanage}"
  if [[ "$legacy_dir" != /* ]]; then
    legacy_dir="${base_dir%/}/${legacy_dir#/}"
  fi
  legacy_dir="${legacy_dir%/}/_legacy"
  printf "%s" "$legacy_dir"
}

legacy_backup_path() {
  local path="$1"
  local base_dir="$2"
  local legacy_dir
  legacy_dir="$(legacy_backup_dir "$base_dir")"
  mkdir -p "$legacy_dir" 2>/dev/null || true
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local dest="${legacy_dir%/}/$(basename "$path").${ts}"

  if [[ -L "$path" && ! -e "$path" ]]; then
    mv "$path" "$dest" 2>/dev/null && log info "[SELF] Archived legacy link: $path -> $dest"
    return 0
  fi

  if declare -F safe_move_or_copy_and_clean >/dev/null 2>&1; then
    if safe_move_or_copy_and_clean "$path" "$dest" move; then
      return 0
    fi
  else
    if mv "$path" "$dest" 2>/dev/null; then
      log info "[SELF] Archived legacy path: $path -> $dest"
      return 0
    fi
  fi
  log warn "[SELF] Failed to archive legacy path: $path"
  return 1
}

legacy_link_path() {
  local target="$1"
  local new_script="$2"
  local base_dir="$3"
  local new_resolved
  new_resolved="$(legacy_resolve_path "$new_script")"

  if [[ -e "$target" || -L "$target" ]]; then
    local current
    current="$(legacy_resolve_path "$target")"
    if [[ -n "$current" && "$current" == "$new_resolved" ]]; then
      return 0
    fi
    legacy_backup_path "$target" "$base_dir"
  fi

  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  ln -sf "$new_script" "$target" && log info "[SELF] Legacy symlink: $target -> $new_script"
}

legacy_warn_shell_alias() {
  local rc_files=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")
  local found=false
  for rc in "${rc_files[@]}"; do
    if [[ -f "$rc" ]] && grep -qE 'inmanage\(\)|inmanage\.sh' "$rc" 2>/dev/null; then
      found=true
      break
    fi
  done
  if [[ "$found" == true ]]; then
    log warn "[SELF] Shell alias/function detected for inmanage in your rc files."
    log warn "[SELF] Remove legacy lines like: inmanage() { cd /base && sudo -u www-data ./inmanage.sh \"$@\"; }"
  fi
}

legacy_create_symlinks() {
  local base_dir="$1"
  local new_script="$2"
  local targets=(
    "${base_dir%/}/inmanage.sh"
    "${base_dir%/}/inmanage"
    "${base_dir%/}/inm"
    "${base_dir%/}/.inmanage/inmanage.sh"
  )
  for target in "${targets[@]}"; do
    legacy_link_path "$target" "$new_script" "$base_dir"
  done
}

maybe_migrate_legacy_cli() {
  local args=("$@")
  local compat="${INM_CLI_COMPATIBILITY:-}"
  if [[ -n "${INM_LEGACY_MIGRATION_DONE:-}" ]]; then
    return 0
  fi
  local legacy_mode="${NAMED_ARGS[legacy_migration]:-${NAMED_ARGS[legacy-migration]:-${INM_LEGACY_MIGRATION:-}}}"
  if [[ "$compat" == "new" ]]; then
    return 0
  fi
  if [[ "$compat" == "legacy" || "$compat" == "old" ]] && [[ ! "${legacy_mode,,}" =~ ^(force|yes|y)$ ]]; then
    return 0
  fi
  if [[ "${legacy_mode,,}" =~ ^(0|no|false|off|skip)$ ]]; then
    return 0
  fi
  if [[ "$CMD_CONTEXT" == "self" || "$CMD_CONTEXT" == "help" || "$SHOW_FUNCTION_HELP" == true ]]; then
    return 0
  fi

  local base_dir="${INM_BASE_DIRECTORY:-$PWD}"
  base_dir="${base_dir%/}"
  local script_path
  script_path="$(legacy_resolve_path "$0")"

  local legacy_detected=false
  if [[ -e "${base_dir%/}/inmanage.sh" || -L "${base_dir%/}/inmanage.sh" ]]; then
    legacy_detected=true
  fi
  if [[ -e "${base_dir%/}/.inmanage/inmanage.sh" || -L "${base_dir%/}/.inmanage/inmanage.sh" ]]; then
    legacy_detected=true
  fi
  if [[ "$script_path" == "${base_dir%/}/"* ]]; then
    legacy_detected=true
  fi

  if [[ "$legacy_detected" != true ]]; then
    return 0
  fi

  local current_user
  current_user="$(whoami)"
  if [[ -n "${INM_ENFORCED_USER:-}" && "$current_user" == "${INM_ENFORCED_USER}" && -n "${SUDO_USER:-}" && "$SUDO_USER" != "$current_user" ]]; then
    log warn "[SELF] Legacy CLI detected while running as ${INM_ENFORCED_USER}. Re-run as your admin user to migrate."
    legacy_warn_shell_alias
    return 0
  fi

  if ! legacy_is_interactive; then
    log warn "[SELF] Legacy CLI detected but no TTY available. Run 'inmanage self install' to migrate."
    legacy_warn_shell_alias
    return 0
  fi

  local do_migrate=false
  if [[ "${legacy_mode,,}" =~ ^(force|yes|y)$ ]]; then
    do_migrate=true
  else
    if prompt_confirm "LEGACY_MIGRATE" "yes" "Legacy inmanage install detected. Migrate to the new CLI now? (yes/no):" false 120; then
      do_migrate=true
    fi
  fi

  if [[ "$do_migrate" != true ]]; then
    if declare -F env_set >/dev/null 2>&1 && [ -f "${INM_SELF_ENV_FILE:-}" ]; then
      env_set cli "INM_CLI_COMPATIBILITY=\"legacy\"" >/dev/null 2>&1 || true
    fi
    log info "[SELF] Staying on legacy bootstrap. To migrate later: inmanage self install"
    legacy_warn_shell_alias
    return 0
  fi

  log info "[SELF] Migrating legacy install to new CLI (fast)."
  log info "[SELF] Note: replace old cronjobs to use the new CLI paths after migration."
  install_self || {
    log err "[SELF] Migration failed during install."
    return 1
  }

  local new_script="${INM_SELF_INSTALL_SCRIPT:-}"
  if [[ -z "$new_script" || ! -f "$new_script" ]]; then
    log err "[SELF] Cannot locate new CLI script after install."
    return 1
  fi

  legacy_create_symlinks "$base_dir" "$new_script"

  if declare -F env_set >/dev/null 2>&1 && [ -f "${INM_SELF_ENV_FILE:-}" ]; then
    env_set cli "INM_CLI_COMPATIBILITY=\"new\"" >/dev/null 2>&1 || true
  fi
  export INM_CLI_COMPATIBILITY="new"
  legacy_warn_shell_alias

  log ok "[SELF] Migration complete. Re-launching..."
  export INM_LEGACY_MIGRATION_DONE=1
  export INM_CHILD_REEXEC=1
  exec "$new_script" "${args[@]}"
}
