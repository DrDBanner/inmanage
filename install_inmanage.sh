#!/usr/bin/env bash
set -euo pipefail

# Simple bootstrap installer for inmanage (system/user/project).
# Intended to be fetched via curl|bash or run from a checked-out repo.

APP_NAME="inmanage"
REPO_URL="https://github.com/DrDBanner/inmanage.git"
INSTALLER_BRANCH="${INSTALLER_BRANCH:-development}"
BRANCH="${BRANCH:-$INSTALLER_BRANCH}"

MODE="${MODE:-system}"          # system|user|project
TARGET_DIR="${TARGET_DIR:-}"
SYMLINK_DIR="${SYMLINK_DIR:-}"
SOURCE_DIR="${SOURCE_DIR:-}"    # optional: use existing checkout instead of git clone
MODE_SET=false
ORIG_ARGS=()

log() {
  local level="$1"; shift
  printf "[%s] %s\n" "$level" "$*" >&2
}

usage() {
  cat <<EOF
inmanage installer

Usage: bash install_inmanage.sh [--mode system|user|project] [--target DIR] [--symlink-dir DIR] [--branch BRANCH] [--source PATH]

Modes:
  system  (default) install to /usr/local/share/inmanage, symlinks to /usr/local/bin (requires sudo)
  user            install to ~/.inmanage_app, symlinks to ~/.local/bin
  project         install to ./ .inmanage_app, symlinks locally

Options:
  --source PATH   Use an existing checkout at PATH instead of git cloning (useful with mounted folders/air-gapped installs).

Examples:
  curl -fsSL ${REPO_URL%.*}/raw/${BRANCH}/install_inmanage.sh | sudo BRANCH=${BRANCH} bash
  curl -fsSL ${REPO_URL%.*}/raw/${BRANCH}/install_inmanage.sh | bash -s -- --mode user
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="$2"; MODE_SET=true; shift 2 ;;
      --target) TARGET_DIR="$2"; shift 2 ;;
      --symlink-dir) SYMLINK_DIR="$2"; shift 2 ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --source) SOURCE_DIR="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) log ERR "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log ERR "Missing required command: $1"; exit 1; }
}

rerun_with_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    log ERR "System mode requires sudo. Please rerun with sudo."
    exit 1
  fi
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    log INFO "Re-running installer with sudo (system mode)."
    exec sudo --preserve-env=BRANCH,INSTALLER_BRANCH,TARGET_DIR,SYMLINK_DIR,SOURCE_DIR \
      bash "${BASH_SOURCE[0]}" --mode system "${ORIG_ARGS[@]}"
  fi
  log ERR "System mode requires sudo. Please rerun with sudo."
  exit 1
}

pick_defaults() {
  if [[ "$MODE" == "system" && ${EUID:-$(id -u)} -ne 0 ]]; then
    if [[ "$MODE_SET" == true ]]; then
      log ERR "System mode requires root (sudo). Please rerun with sudo."
      exit 1
    fi
    if [[ -t 0 && -t 1 ]]; then
      log WARN "System mode requires root. Select another mode:"
      printf "  [1] User (no sudo)\n  [2] Project (current dir)\n  [3] System (requires sudo)\n"
      read -r -p "[1] > " choice
      case "${choice:-1}" in
        1) MODE="user" ;;
        2) MODE="project" ;;
        3) rerun_with_sudo ;;
        *) log ERR "Invalid selection: $choice"; exit 1 ;;
      esac
    else
      log ERR "System mode requires root (sudo). Use --mode user or --mode project."
      exit 1
    fi
  fi

  case "$MODE" in
    system)
      TARGET_DIR="${TARGET_DIR:-/usr/local/share/${APP_NAME}}"
      SYMLINK_DIR="${SYMLINK_DIR:-/usr/local/bin}"
      ;;
    user)
      TARGET_DIR="${TARGET_DIR:-$HOME/.inmanage_app}"
      SYMLINK_DIR="${SYMLINK_DIR:-$HOME/.local/bin}"
      ;;
    project)
      TARGET_DIR="${TARGET_DIR:-$(pwd)/.inmanage_app}"
      SYMLINK_DIR="${SYMLINK_DIR:-$(pwd)}"
      ;;
    *) log ERR "Invalid mode: $MODE"; exit 1 ;;
  esac
}

ensure_dirs() {
  mkdir -p "$TARGET_DIR"
  mkdir -p "$SYMLINK_DIR"
}

clone_or_update() {
  if [[ -n "$SOURCE_DIR" ]]; then
    log INFO "Using local source: $SOURCE_DIR"
    log WARN "Note: --source uses rsync --delete; files in the target not present in source will be removed."
    if [[ ! -d "$SOURCE_DIR" || ! -f "$SOURCE_DIR/inmanage.sh" ]]; then
      log ERR "SOURCE_DIR must contain an inmanage checkout (missing inmanage.sh): $SOURCE_DIR"
      exit 1
    fi
    if [[ "$(realpath "$SOURCE_DIR")" == "$(realpath "$TARGET_DIR")" ]]; then
      log ERR "SOURCE_DIR and TARGET_DIR must differ."
      exit 1
    fi
    require_cmd rsync
    rsync -a --delete "$SOURCE_DIR/." "$TARGET_DIR/"
    return
  fi

  if [[ -d "$TARGET_DIR/.git" ]]; then
    log INFO "Updating existing checkout at $TARGET_DIR (branch: $BRANCH)"
    git -C "$TARGET_DIR" fetch --tags origin "$BRANCH"
    git -C "$TARGET_DIR" checkout "$BRANCH"
    git -C "$TARGET_DIR" pull --ff-only origin "$BRANCH"
  else
    log INFO "Cloning $REPO_URL (branch: $BRANCH) into $TARGET_DIR"
    git clone --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
  fi
}

install_symlinks() {
  local src="$TARGET_DIR/inmanage.sh"
  for name in "$APP_NAME" "inm"; do
    local link="$SYMLINK_DIR/$name"
    ln -sf "$src" "$link"
    log INFO "Symlinked $link -> $src"
  done
}

post_message() {
  cat <<EOF

Installed ${APP_NAME} to: $TARGET_DIR
Symlinks in: $SYMLINK_DIR

Try:
  $APP_NAME -h
  $APP_NAME core install --help

Project config will live in .inmanage/.env.inmanage by default.
EOF
}

warn_shadowing() {
  local detect_user="${SUDO_USER:-$USER}"
  local rc_files=("/home/$detect_user/.bashrc" "/home/$detect_user/.zshrc")
  for rc in "${rc_files[@]}"; do
    if [[ -f "$rc" ]] && grep -Eq '^(alias[[:space:]]+inmanage=|inmanage\(\))' "$rc"; then
      log WARN "Detected custom inmanage alias/function in $rc. It may shadow /usr/local/bin/inmanage. Remove/comment it, or use 'inm'."
      break
    fi
  done
}

main() {
  ORIG_ARGS=("$@")
  parse_args "$@"
  require_cmd git
  warn_shadowing
  pick_defaults
  log INFO "Mode: $MODE | Branch: $BRANCH"
  log INFO "Target: $TARGET_DIR | Symlinks: $SYMLINK_DIR"

  ensure_dirs
  clone_or_update
  install_symlinks
  post_message
}

main "$@"
