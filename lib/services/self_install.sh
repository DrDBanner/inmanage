#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SERVICE_SELF_INSTALL_LOADED:-} ]] && return
__SERVICE_SELF_INSTALL_LOADED=1

# ---------------------------------------------------------------------
# self_detect_web_user()
# Find a likely web server user on the system.
# Consumes: system user database (id).
# Computes: first matching user from common list.
# Returns: prints username or empty string.
# ---------------------------------------------------------------------
self_detect_web_user() {
  local candidate=""
  local candidates=(www-data nginx apache httpd)
  for candidate in "${candidates[@]}"; do
    if id -u "$candidate" >/dev/null 2>&1; then
      printf "%s" "$candidate"
      return 0
    fi
  done
  printf "%s" ""
}

# ---------------------------------------------------------------------
# self_normalize_install_mode()
# Normalize install mode input to numeric code.
# Consumes: args: mode.
# Computes: normalized mode string.
# Returns: prints normalized mode.
# ---------------------------------------------------------------------
self_normalize_install_mode() {
  case "$1" in
    1|system) printf "1" ;;
    2|local|user) printf "2" ;;
    3|project) printf "3" ;;
    *) printf "%s" "$1" ;;
  esac
}

# ---------------------------------------------------------------------
# self_resolve_path()
# Resolve a script path to an absolute path if possible.
# Consumes: args: path; deps: resolve_script_path/realpath.
# Computes: resolved path.
# Returns: prints resolved path.
# ---------------------------------------------------------------------
self_resolve_path() {
  if declare -F resolve_script_path >/dev/null 2>&1; then
    resolve_script_path "$1" 2>/dev/null && return
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null && return
  fi
  printf "%s" "$1"
}

# ---------------------------------------------------------------------
# self_write_version_file()
# Write VERSION and VERSION.json for consistent reporting (git installs or release bundles).
# Consumes: args: target_dir, source_dir; deps: git_collect_info.
# Computes: VERSION and VERSION.json content.
# Returns: 0 (best-effort).
# ---------------------------------------------------------------------
self_write_version_file() {
  local target_dir="$1"
  local source_dir="$2"
  local branch="" commit="" dirty="" commit_date=""
  local version_line=""
  local version_value=""

  [[ -z "$target_dir" ]] && return 0
  [[ -z "$source_dir" ]] && source_dir="$target_dir"

  if command -v git >/dev/null 2>&1 && [ -d "$source_dir/.git" ]; then
    git_collect_info "$source_dir" branch commit dirty commit_date || true
  fi
  if [[ -z "$branch" && -z "$commit" && -d "$target_dir/.git" && "$target_dir" != "$source_dir" ]]; then
    git_collect_info "$target_dir" branch commit dirty commit_date || true
  fi

  if [[ -n "$branch" || -n "$commit" ]]; then
    version_line="branch=${branch:-unknown} commit=${commit:-unknown}"
  fi

  if [[ -z "$version_line" && -r "${source_dir%/}/VERSION" ]]; then
    version_line="$(head -n1 "${source_dir%/}/VERSION" 2>/dev/null || true)"
  fi
  if [[ -z "$version_line" && -r "${target_dir%/}/VERSION" ]]; then
    version_line="$(head -n1 "${target_dir%/}/VERSION" 2>/dev/null || true)"
  fi

  if [[ -z "$branch" && "$version_line" =~ branch=([^ ]+) ]]; then
    branch="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$commit" && "$version_line" =~ commit=([0-9a-fA-F]{7,40}) ]]; then
    commit="${BASH_REMATCH[1]}"
  fi
  if [[ -n "$version_line" && "$version_line" != *"branch="* && "$version_line" != *"commit="* ]]; then
    version_value="$version_line"
  fi

  if [[ -n "$version_line" ]]; then
    if ! printf "%s\n" "$version_line" > "${target_dir%/}/VERSION" 2>/dev/null; then
      log warn "[SELF] Failed to write VERSION file to ${target_dir%/}/VERSION"
      return 0
    fi
    chmod 0644 "${target_dir%/}/VERSION" 2>/dev/null || true
  fi
  if [[ -n "$version_line" || -n "$version_value" || -n "$branch" || -n "$commit" ]]; then
    json_escape() {
      local value="$1"
      value="${value//\\/\\\\}"
      value="${value//\"/\\\"}"
      printf "%s" "$value"
    }
    local installed_at=""
    installed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
    local source="unknown"
    if [[ -n "$branch" || -n "$commit" ]]; then
      source="git"
    elif [[ -n "$version_value" ]]; then
      source="release"
    fi
    local version_json
    version_json=$(printf "{\"version\":\"%s\",\"branch\":\"%s\",\"commit\":\"%s\",\"source\":\"%s\",\"installed_at\":\"%s\"}\n" \
      "$(json_escape "$version_value")" \
      "$(json_escape "$branch")" \
      "$(json_escape "$commit")" \
      "$(json_escape "$source")" \
      "$(json_escape "$installed_at")")
    if ! printf "%s" "$version_json" > "${target_dir%/}/VERSION.json" 2>/dev/null; then
      log warn "[SELF] Failed to write VERSION.json to ${target_dir%/}/VERSION.json"
      return 0
    fi
    chmod 0644 "${target_dir%/}/VERSION.json" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------
# install_self()
# Install the CLI into system/user/project locations and create symlinks.
# Consumes: env: NAMED_ARGS, INM_PATH_BASE_DIR, RUN_AS_USER, XDG_DATA_HOME; deps: self_detect_web_user.
# Computes: install path selection and file copy/symlink actions.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
install_self() {
  if [[ "${DRY_RUN:-false}" == true ]]; then
    log info "[DRY-RUN] Skipping self install."
    return 0
  fi
  log debug "[SELF] Checking CLI installation …"

  local can_prompt=false
  [[ -t 0 && -t 1 ]] && can_prompt=true

  local default_bin="/usr/local/bin"
  local source_script
  source_script="$(self_resolve_path "$0")"
  local source_dir
  source_dir="$(dirname "$source_script")"

  local install_dir="${NAMED_ARGS[target_dir]:-${NAMED_ARGS[--target-dir]:-}}"
  local install_mode="${NAMED_ARGS[install_mode]:-${NAMED_ARGS[--install-mode]:-}}"
  local install_owner="${NAMED_ARGS[install_owner]:-${NAMED_ARGS[--install-owner]:-}}"
  local install_perms="${NAMED_ARGS[install_perms]:-${NAMED_ARGS[--install-perms]:-}}"
  local current_user
  current_user="$(whoami)"
  local is_root=false
  [[ ${EUID:-$(id -u)} -eq 0 ]] && is_root=true

  local run_user_default="${RUN_AS_USER:-}"
  if [[ -z "$run_user_default" ]]; then
      if [[ "$is_root" == true ]]; then
          run_user_default="$(self_detect_web_user)"
      else
          run_user_default="$current_user"
      fi
  fi
  local run_user="${NAMED_ARGS[run_user]:-${NAMED_ARGS[--run-user]:-$run_user_default}}"
  if [[ -n "$run_user" ]]; then
      if ! id -u "$run_user" >/dev/null 2>&1; then
          log warn "[SELF] User '$run_user' does not exist on this system. Ignoring enforced user."
          run_user=""
      else
          log info "[SELF] Will target run-user: $run_user"
      fi
  fi

  local user_home="${HOME:-}"
  if [[ -n "$run_user" && "$run_user" != "$current_user" ]]; then
      user_home="$(getent passwd "$run_user" 2>/dev/null | cut -d: -f6)"
      [[ -z "$user_home" ]] && user_home="/home/$run_user"
  fi
  if [[ -z "$user_home" ]]; then
      if [[ -n "$run_user" ]]; then
          user_home="/home/$run_user"
      else
          user_home="/home/$current_user"
      fi
  fi
  local user_data_home=""
  if [[ ( -z "$run_user" || "$run_user" == "$current_user" ) && -n "${XDG_DATA_HOME:-}" ]]; then
      user_data_home="$XDG_DATA_HOME"
  else
      user_data_home="${user_home%/}/.local/share"
  fi
  user_data_home="${user_data_home%/}"
  local local_bin="${user_home%/}/.local/bin"
  local default_user_dir="${user_data_home%/}/inmanage"
  local symlink_dir="${NAMED_ARGS[symlink_dir]:-${NAMED_ARGS[--symlink-dir]:-}}"

  # Derive a base_dir for project mode defaults
  local base_dir="${INM_PATH_BASE_DIR:-$PWD}"
  base_dir="$(ensure_trailing_slash "$base_dir")"

  if [[ -z "$install_mode" ]]; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      install_mode="1"
    else
      install_mode="2"
    fi
  fi
  install_mode="$(self_normalize_install_mode "$install_mode")"

  if [[ -n "$run_user" && "$run_user" != "$current_user" && ${EUID:-$(id -u)} -ne 0 ]]; then
      log err "[SELF] Enforced user '$run_user' differs; re-run with sudo/root."
      return 1
  fi

  local default_project_dir="${base_dir%/}/.inmanage/cli"

  if [[ -z "$install_dir" ]]; then
    case "$install_mode" in
      1) install_dir="/usr/local/share/inmanage" ;;
      2) install_dir="$default_user_dir" ;;
      3) install_dir="$default_project_dir" ;;
      *) log err "[SELF] Invalid mode: $install_mode" ; return 1 ;;
    esac
  fi

  # No interactive install_dir prompt; use explicit flags/env only.
  local link_dir="$symlink_dir"
  if [[ -z "$link_dir" ]]; then
    case "$install_mode" in
      1) link_dir="$default_bin" ;;
      2)
        if [[ -n "$run_user" && "$run_user" != "$current_user" && ${EUID:-$(id -u)} -eq 0 ]]; then
            link_dir="$default_bin"
        else
            link_dir="$local_bin"
        fi
        ;;
      3) link_dir="${base_dir%/}" ;;
    esac
  fi

  local current_mode="unknown"
  if [[ "$source_dir" == "/usr/local/share/inmanage" ]]; then
    current_mode="1"
  elif [[ "$source_dir" == "$default_user_dir" ]]; then
    current_mode="2"
  elif [[ -n "$base_dir" && "$source_dir" == "$default_project_dir" ]]; then
    current_mode="3"
  elif [[ -n "$base_dir" && "$source_dir" == "${base_dir%/}"* ]]; then
    current_mode="3"
  fi

  if [[ "$(self_resolve_path "$install_dir")" == "$(self_resolve_path "$source_dir")" ]]; then
      if [[ "$current_mode" != "unknown" && "$install_mode" == "$current_mode" ]]; then
          log ok "[SELF] Already installed in this mode. All good, nothing to do."
          return 0
      fi
      log err "[SELF] Source and target install directory are the same. Choose a different target."
      return 1
  fi

  if [[ "$install_mode" == "3" && -f "$(pwd)/.inmanage/inmanage.sh" && "$install_dir" != "$(pwd)/.inmanage" ]]; then
      log warn "[SELF] Legacy project install detected at .inmanage/; new target is $install_dir"
      log warn "[SELF] Consider migrating after this install if you want to keep config/data separate."
  fi

  log debug "[SELF] Installing to: $install_dir"
  mkdir -p "$install_dir" || { log err "[SELF] Cannot create $install_dir"; return 1; }

  if [[ "${DEBUG:-false}" == true || "${NAMED_ARGS[debug]:-false}" == true ]]; then
      log debug "[SELF] Copying CLI from $source_dir to $install_dir (mode=copy)"
  fi
  spinner_run_mode normal "Installing inmanage..." safe_move_or_copy_and_clean "$(dirname "$source_script")" "$install_dir" copy || {
      log err "[SELF] Failed to copy files"; return 1;
  }
  self_write_version_file "$install_dir" "$source_dir"

  if [[ "$install_mode" == "2" && ${EUID:-$(id -u)} -eq 0 && "$run_user" != "root" ]]; then
      local run_group
      run_group="$(id -gn "$run_user" 2>/dev/null || true)"
      [[ -z "$run_group" ]] && run_group="$run_user"
      if ! chown -R "$run_user:$run_group" "$install_dir" 2>/dev/null; then
          log warn "[SELF] Failed to set ownership on $install_dir to $run_user:$run_group"
      fi
  fi
  if [[ "$install_mode" == "1" && ${EUID:-$(id -u)} -eq 0 ]]; then
      if [[ -z "$install_perms" ]]; then
          if ! chmod -R go+rX "$install_dir" 2>/dev/null; then
              log warn "[SELF] Failed to relax permissions on $install_dir for non-root users."
          fi
      fi
  fi

  if [[ -n "$install_owner" ]]; then
      if ! chown -R "$install_owner" "$install_dir" 2>/dev/null; then
          log warn "[SELF] Failed to set ownership on $install_dir to $install_owner"
      fi
  fi
  if [[ -n "$install_perms" ]]; then
      local dir_mode file_mode
      IFS=':' read -r dir_mode file_mode <<< "$install_perms"
      if [[ -z "$dir_mode" || -z "$file_mode" ]]; then
          log warn "[SELF] --install-perms expects DIR:FILE (e.g. 775:664); got '$install_perms'"
      else
          if command -v find >/dev/null 2>&1; then
              find "$install_dir" -type d -exec chmod "$dir_mode" {} + 2>/dev/null || true
              # Preserve executable bits by only applying file_mode to non-executable files.
              find "$install_dir" -type f ! -perm -111 -exec chmod "$file_mode" {} + 2>/dev/null || true
          else
              log warn "[SELF] 'find' not available; skipping --install-perms."
          fi
      fi
  fi

  local bin_source="$install_dir/inmanage.sh"
  INM_SELF_INSTALL_SCRIPT="$bin_source"
  # shellcheck disable=SC2034
  INM_SELF_INSTALL_MODE="$install_mode"
  local targets=("inmanage" "inm")

  case "$install_mode" in
    1)
      log info "[SELF] Global install selected; set INM_EXEC_USER to the user that owns the app files (often www-data/nginx/apache/httpd, or your login user on shared hosting)."
      if [[ ! -d "$link_dir" ]]; then
        if ! mkdir -p "$link_dir" 2>/dev/null; then
          if command -v sudo &>/dev/null && [[ "$can_prompt" == true ]]; then
            prompt_var "ROOTPW" "Root password needed to prepare $link_dir" "" silent=true timeout=15 || return 1
            echo "$ROOTPW" | sudo -S mkdir -p "$link_dir"
          else
            log err "[SELF] Cannot create $link_dir without sudo."
            return 1
          fi
        fi
      fi
      for name in "${targets[@]}"; do
        if [[ -w "$link_dir" ]]; then
          ln -sf "$bin_source" "$link_dir/$name"
        elif command -v sudo &>/dev/null && [[ "$can_prompt" == true ]]; then
          prompt_var "ROOTPW" "Root password needed to install system-wide" "" silent=true timeout=15 || return 1
          echo "$ROOTPW" | sudo -S ln -sf "$bin_source" "$link_dir/$name"
        else
          log err "[SELF] Cannot write to $link_dir and sudo not available"
          return 1
        fi
      done
      log ok "[SELF] Installed globally in $link_dir"
      ;;
    2)
      if [[ -n "$run_user" && "$run_user" != "$current_user" ]]; then
          log info "[SELF] User-mode install targets '$run_user' (current user: $current_user)."
      elif [[ ${EUID:-$(id -u)} -ne 0 ]]; then
          log info "[SELF] User-mode install is only accessible to $current_user. For web user access, re-run with sudo --run-user <web> or use --install-mode=system."
      fi
      mkdir -p "$link_dir" || { log err "[SELF] Cannot create $link_dir"; return 1; }
      if [[ ${EUID:-$(id -u)} -eq 0 && -n "$run_user" && "$run_user" != "root" ]]; then
          local link_group
          link_group="$(id -gn "$run_user" 2>/dev/null || true)"
          [[ -z "$link_group" ]] && link_group="$run_user"
          if [[ "$link_dir" == "${user_home%/}/"* ]]; then
              chown "$run_user:$link_group" "$link_dir" 2>/dev/null || true
          fi
      fi
      for name in "${targets[@]}"; do
        ln -sf "$bin_source" "$link_dir/$name"
      done
      log ok "[SELF] Installed locally in $link_dir"
      if [[ -n "$run_user" && "$run_user" != "$current_user" ]]; then
        log info "[SELF] Ensuring global symlinks for enforced user '$run_user'."
        if [[ ! -d "$default_bin" ]]; then
            mkdir -p "$default_bin" || { log err "[SELF] Cannot create $default_bin"; return 1; }
        fi
        for name in "${targets[@]}"; do
          ln -sf "$bin_source" "$default_bin/$name"
        done
        log ok "[SELF] Installed global symlinks in $default_bin"
      elif [[ ":$PATH:" != *":$link_dir:"* ]]; then
        log warn "[SELF] PATH does not include $link_dir; add it manually."
        log info "[SELF] One-liner example: echo 'export PATH=\"$link_dir:\$PATH\"' >> ~/.profile && source ~/.profile"
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

      spinner_run_mode normal "Installing inmanage..." safe_move_or_copy_and_clean "$(dirname "$source_path")" "$app_dir" || {
          log err "[INSTALL] Could not deploy to project directory."
          exit 1
      }

      local app_source="$app_dir/inmanage.sh"
      local legacy_app_dir="${project_root}/.inmanage"

      local link_root="${link_dir:-$project_root}"
      if [[ ! -d "$link_root" ]]; then
          mkdir -p "$link_root" || log err "[INSTALL] Failed to create symlink directory: $link_root"
      fi

      # Symlinks in project root (update legacy if pointing to .inmanage)
      for name in "inmanage" "inm"; do
          local link="${link_root}/${name}"
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
      log info "[INSTALL] Tip: Use ./inm (project root). For global access: ln -sf \"${link_root%/}/inm\" ~/.local/bin/inm"

      if [[ -n "$run_user" && "$run_user" != "$current_user" ]]; then
          log info "[INSTALL] Ensuring global symlinks for enforced user '$run_user'."
          if [[ ! -d "$default_bin" ]]; then
              mkdir -p "$default_bin" || { log err "[INSTALL] Cannot create $default_bin"; return 1; }
          fi
          for name in "inmanage" "inm"; do
              ln -sf "$app_source" "$default_bin/$name"
          done
          log ok "[INSTALL] Installed global symlinks in $default_bin"
      fi

      echo
      log info "Tip: You can install globally anytime via 'inmanage self install --install-mode=1'"

      log info "[INSTALL] Tip: Run 'inm -h' for help."

      return 0
      ;;
  esac

  log info "[SELF] Tip: Run 'inm -h' for help."
  if declare -F hash >/dev/null 2>&1 || command -v hash >/dev/null 2>&1; then
    hash -r 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------
# self_update()
# Update the CLI in-place from a git checkout.
# Consumes: env: DRY_RUN; deps: git_pull_ff_only/self_resolve_path.
# Computes: git pull in install root.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
self_update() {
  local -A args=()
  parse_named_args args "$@"
  local legacy_mode
  legacy_mode="$(args_get args "" legacy_migration legacy-migration)"
  local script_path="$0"
  script_path="$(self_resolve_path "$0")"
  local root
  root="$(cd "$(dirname "$script_path")" && pwd)"
  if [[ ! -x "$root" || ! -r "$root" ]]; then
    log warn "[SELF] Cannot access install path: $root (try: sudo inm self update)."
    return 1
  fi
  if [[ ! -d "$root/.git" ]]; then
    log warn "[SELF] No git metadata found at $root; re-run installer to update."
    return 1
  fi
  if [[ ! -w "$root" || ! -w "$root/.git" ]] && [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    log err "[SELF] No write access to $root. Re-run with sudo or change ownership."
    return 1
  fi
  if [[ "${DRY_RUN:-false}" == true ]]; then
    log info "[DRY-RUN] Would run git pull in $root"
    return 0
  fi
  log info "[SELF] Updating CLI in $root (git pull)"
  if git_pull_ff_only "$root"; then
    self_write_version_file "$root" "$root"
    log ok "[SELF] Update completed."
    if declare -F update_notice_clear >/dev/null 2>&1; then
      update_notice_clear "cli"
    fi
    if declare -F update_notice_mark_checked >/dev/null 2>&1; then
      update_notice_mark_checked
    fi
    if [[ "${legacy_mode,,}" =~ ^(force|yes|y)$ ]]; then
      if declare -F self_migrations_legacy_detected >/dev/null 2>&1; then
        if self_migrations_legacy_detected; then
          log info "[SELF] Removing legacy local install (--legacy-migration=force)."
          self_migrations_legacy_cleanup
        else
          log info "[SELF] No legacy local install found."
        fi
      fi
    fi
  else
    self_write_version_file "$root" "$root"
    log err "[SELF] git pull failed; resolve manually."
    return 1
  fi
}

# ---------------------------------------------------------------------
# self_switch_mode()
# Reinstall the CLI in a different mode and clean old links optionally.
# Consumes: env: NAMED_ARGS, DRY_RUN; deps: install_self/safe_rm_rf.
# Computes: mode switch and cleanup.
# Returns: 0 on success, non-zero on failure.
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
    safe_rm_rf "$old_root" "$(dirname "$old_root")"
  else
    log info "[SELF] Old install left at $old_root (use --force-clean-old to remove)."
  fi
}

# ---------------------------------------------------------------------
# self_uninstall()
# Remove CLI symlinks and optionally delete install directory.
# Consumes: env: NAMED_ARGS, XDG_DATA_HOME, INM_PATH_BASE_DIR, DRY_RUN; deps: safe_rm_rf.
# Computes: symlink cleanup and optional deletion.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
self_uninstall() {
  local script_path="$0"
  script_path="$(self_resolve_path "$0")"
  local root
  root="$(cd "$(dirname "$script_path")" && pwd)"
  local force_delete="${NAMED_ARGS[force]:-${NAMED_ARGS[--force]:-false}}"
  local user_data_home="${XDG_DATA_HOME:-${HOME%/}/.local/share}"
  user_data_home="${user_data_home%/}"
  local default_user_dir="${user_data_home}/inmanage"
  local default_project_dir=""
  if [[ -n "${INM_PATH_BASE_DIR:-}" ]]; then
      default_project_dir="${INM_PATH_BASE_DIR%/}/.inmanage/cli"
  fi
  local mode="unknown"
  if [[ "$root" == "/usr/local/share/inmanage" ]]; then
      mode="system"
  elif [[ -n "${HOME:-}" && "$root" == "$default_user_dir" ]]; then
      mode="user"
  elif [[ "$root" == */.inmanage/cli ]]; then
      mode="project"
  elif [[ -n "$default_project_dir" && "$root" == "$default_project_dir" ]]; then
      mode="project"
  elif [[ -n "${INM_PATH_BASE_DIR:-}" && "$root" == "${INM_PATH_BASE_DIR%/}"* ]]; then
      mode="project"
  fi

  if [[ "${DRY_RUN:-false}" == true ]]; then
    log info "[DRY-RUN] Would uninstall CLI at $root (force delete=$force_delete)"
    return 0
  fi

  log info "[SELF] Uninstalling CLI from $root"
  local links=()
  case "$mode" in
      system)
          links+=("/usr/local/bin/inmanage" "/usr/local/bin/inm")
          ;;
      user)
          links+=("${HOME%/}/.local/bin/inmanage" "${HOME%/}/.local/bin/inm")
          ;;
      project)
          local project_root=""
          if [[ "$root" == */.inmanage/cli ]]; then
              project_root="$(dirname "$(dirname "$root")")"
          elif [[ -n "${INM_PATH_BASE_DIR:-}" ]]; then
              project_root="${INM_PATH_BASE_DIR%/}"
          fi
          if [[ -n "$project_root" ]]; then
              links+=("${project_root%/}/inmanage" "${project_root%/}/inm")
          fi
          ;;
      *)
          links+=("/usr/local/bin/inmanage" "/usr/local/bin/inm" "${HOME%/}/.local/bin/inmanage" "${HOME%/}/.local/bin/inm" "$(pwd)/inmanage" "$(pwd)/inm")
          ;;
  esac
  for link in "${links[@]}"; do
    if [[ -L "$link" ]]; then
      local target
      target="$(readlink "$link" 2>/dev/null || true)"
      local link_dir resolved_target
      link_dir="$(dirname "$link")"
      if [[ -n "$target" && "$target" != /* ]]; then
        resolved_target="${link_dir%/}/$target"
      else
        resolved_target="$target"
      fi
      if [[ "$resolved_target" == "$script_path" || "$resolved_target" == "$root/inmanage.sh" || "$resolved_target" == "$root/./inmanage.sh" ]]; then
        log info "[SELF] Removing symlink: $link"
        rm -f "$link"
      fi
    fi
  done

  if [[ "$force_delete" == true ]]; then
    case "$root" in
      "/"|"/usr"|"/usr/local"|"/usr/local/bin"|"/usr/bin"|"/bin"|"/usr/sbin"|"/sbin")
        log err "[SELF] Refusing to remove unsafe path: $root"
        return 1
        ;;
    esac
    log warn "[SELF] Removing install directory (destructive): $root"
    safe_rm_rf "$root" "$(dirname "$root")"
  else
    log info "[SELF] Install directory left at $root (use --force to delete, destructive)."
  fi

  log ok "[SELF] Uninstall steps completed."
}

# ---------------------------------------------------------------------
# self_version()
# Show CLI version and install metadata.
# Consumes: env: INM_SELF_INSTALL_MODE, INM_PATH_BASE_DIR; deps: git_collect_info/self_resolve_path.
# Computes: version output.
# Returns: 0 after logging.
# ---------------------------------------------------------------------
self_version() {
  local -A cli_info=()
  cli_collect_info cli_info

  local root="${cli_info[root]}"
  log info "[SELF] CLI path: $root"
  if [[ -n "$root" && ( ! -x "$root" || ! -r "$root" ) ]]; then
    log warn "[SELF] Cannot access install path: $root (try: sudo inm self version)."
  fi

  if [[ "${cli_info[git_present]}" == true ]]; then
    log info "[SELF] Source: git checkout (branch=${cli_info[branch]} commit=${cli_info[commit]}${cli_info[dirty]})"
    if echo "${cli_info[git_error]:-}" | grep -qi "dubious ownership"; then
      log warn "[SELF] Git ownership check blocked access. Run: git config --global --add safe.directory $root"
    elif echo "${cli_info[git_error]:-}" | grep -qi "permission denied"; then
      log warn "[SELF] Git metadata not readable at $root (try: sudo or adjust ownership)."
    fi
    [[ -n "${cli_info[commit_date]:-}" ]] && log info "[SELF] Last commit date: ${cli_info[commit_date]}"
  elif [[ -n "${cli_info[commit]:-}" || -n "${cli_info[version]:-}" ]]; then
    log info "[SELF] Source: snapshot (branch=${cli_info[branch]:-unknown} commit=${cli_info[commit]:-unknown})"
  else
    log warn "[SELF] Source: no git metadata (tarball/snapshot install)"
  fi

  if [[ -n "${cli_info[version]:-}" ]]; then
    log info "[SELF] Version file: ${cli_info[version]}"
  fi

  log info "[SELF] Install mode: ${cli_info[install_mode]:-unknown}"
  log info "[SELF] App versions: run 'inm core versions'"
}

# ---------------------------------------------------------------------
# Legacy migration helpers
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# legacy_is_interactive()
# Check if a TTY is available for prompts.
# Consumes: tty availability.
# Computes: interactive state.
# Returns: 0 if interactive, 1 otherwise.
# ---------------------------------------------------------------------
legacy_is_interactive() {
  [[ -t 0 && -t 1 ]]
}

# ---------------------------------------------------------------------
# legacy_resolve_path()
# Resolve a path for legacy migration.
# Consumes: args: target; deps: resolve_script_path/realpath.
# Computes: resolved path.
# Returns: prints resolved path.
# ---------------------------------------------------------------------
legacy_resolve_path() {
  local target="$1"
  resolve_script_path "$target" 2>/dev/null && return
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null && return
  fi
  printf "%s" "$target"
}

# ---------------------------------------------------------------------
# legacy_backup_dir()
# Compute the legacy backup directory path.
# Consumes: args: base_dir; env: INM_CONFIG_ROOT.
# Computes: backup dir path.
# Returns: prints backup directory.
# ---------------------------------------------------------------------
legacy_backup_dir() {
  local base_dir="$1"
  local legacy_dir="${INM_CONFIG_ROOT:-.inmanage}"
  if [[ "$legacy_dir" != /* ]]; then
    legacy_dir="${base_dir%/}/${legacy_dir#/}"
  fi
  legacy_dir="${legacy_dir%/}/_legacy"
  printf "%s" "$legacy_dir"
}

# ---------------------------------------------------------------------
# legacy_backup_path()
# Move or archive a legacy path into the backup directory.
# Consumes: args: path, base_dir; deps: safe_move_or_copy_and_clean.
# Computes: archive destination.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
legacy_backup_path() {
  local path="$1"
  local base_dir="$2"
  local legacy_dir
  legacy_dir="$(legacy_backup_dir "$base_dir")"
  mkdir -p "$legacy_dir" 2>/dev/null || true
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local dest
  dest="${legacy_dir%/}/$(basename "$path").${ts}"

  if [[ -L "$path" && ! -e "$path" ]]; then
    mv "$path" "$dest" 2>/dev/null && log info "[SELF] Archived legacy link: $path -> $dest"
    return 0
  fi

  if safe_move_or_copy_and_clean "$path" "$dest" move; then
    return 0
  fi
  log warn "[SELF] Failed to archive legacy path: $path"
  return 1
}

# ---------------------------------------------------------------------
# legacy_cleanup_repo()
# Remove legacy repo content under .inmanage while keeping config files.
# Consumes: args: legacy_root, base_dir; deps: legacy_backup_path.
# ---------------------------------------------------------------------
legacy_cleanup_repo() {
  local legacy_root="$1"
  local base_dir="$2"
  [[ -z "$legacy_root" ]] && return 0
  [[ ! -d "$legacy_root" ]] && return 0

  if [[ ! -d "$legacy_root/.git" && ! -f "$legacy_root/inmanage.sh" && ! -d "$legacy_root/lib" ]]; then
    return 0
  fi

  log info "[SELF] Cleaning legacy repo content in $legacy_root (keeping .env.inmanage/.env.provision/history.log)."
  local entry base
  shopt -s dotglob nullglob
  for entry in "$legacy_root"/*; do
    base="$(basename "$entry")"
    case "$base" in
      .|..|.env.inmanage|.env.provision|history.log|_legacy) continue ;;
    esac
    legacy_backup_path "$entry" "$base_dir"
  done
  shopt -u dotglob nullglob
}

# ---------------------------------------------------------------------
# legacy_link_path()
# Create a legacy symlink pointing to the new script.
# Consumes: args: target, new_script, base_dir; deps: legacy_backup_path.
# Computes: symlink update.
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# legacy_warn_shell_alias()
# Warn about legacy shell aliases/functions.
# Consumes: env: HOME.
# Computes: rc file scan.
# Returns: 0 after logging.
# ---------------------------------------------------------------------
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
    log warn '[SELF] Remove legacy lines like: inmanage() { cd /base && sudo -u www-data ./inmanage.sh "$@"; }'
  fi
}

# ---------------------------------------------------------------------
# legacy_create_symlinks()
# Create legacy compatibility symlinks.
# Consumes: args: base_dir, new_script.
# Computes: symlink creation.
# Returns: 0 on completion.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# maybe_migrate_legacy_cli()
# Detect and migrate legacy CLI installs when applicable.
# Consumes: args: original args; env: INM_SELF_CLI_COMPAT_MODE, NAMED_ARGS, INM_PATH_BASE_DIR.
# Computes: migration flow and re-exec.
# Returns: 0 if no migration, otherwise execs new CLI.
# ---------------------------------------------------------------------
maybe_migrate_legacy_cli() {
  local args=("$@")
  local compat="${INM_SELF_CLI_COMPAT_MODE:-}"
  if [[ -n "${INM_LEGACY_MIGRATION_DONE:-}" ]]; then
    return 0
  fi
  local legacy_mode="${NAMED_ARGS[legacy_migration]:-${NAMED_ARGS[legacy-migration]:-${INM_LEGACY_MIGRATION:-}}}"
  if [[ "$compat" == "new" || "$compat" == "ultron" ]]; then
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

  local base_dir="${INM_PATH_BASE_DIR:-$PWD}"
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
  if [[ -n "${INM_EXEC_USER:-}" && "$current_user" == "${INM_EXEC_USER}" && -n "${SUDO_USER:-}" && "$SUDO_USER" != "$current_user" ]]; then
    log warn "[SELF] Legacy CLI detected while running as ${INM_EXEC_USER}. Re-run as your admin user to migrate."
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
    if [ -f "${INM_SELF_ENV_FILE:-}" ]; then
      env_set cli "INM_SELF_CLI_COMPAT_MODE=legacy" >/dev/null 2>&1 || true
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

  legacy_cleanup_repo "${base_dir%/}/.inmanage" "$base_dir"
  if [[ "${INM_SELF_INSTALL_MODE:-}" == "3" ]]; then
    legacy_create_symlinks "$base_dir" "$new_script"
  else
    log info "[SELF] Skipping legacy project symlinks (install mode != project)."
  fi

  if [ -f "${INM_SELF_ENV_FILE:-}" ]; then
    env_set cli "INM_SELF_CLI_COMPAT_MODE=ultron" >/dev/null 2>&1 || true
  fi
  export INM_SELF_CLI_COMPAT_MODE="ultron"
  export INM_SELF_CLI_COMPAT_MODE="ultron"
  legacy_warn_shell_alias

  log ok "[SELF] Migration complete. Re-launching..."
  export INM_LEGACY_MIGRATION_DONE=1
  export INM_CHILD_REEXEC=1
  exec "$new_script" "${args[@]}"
}
