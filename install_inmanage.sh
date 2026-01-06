#!/usr/bin/env bash
set -euo pipefail

# Bootstrap installer for inmanage (system/user/project).
# Intended to be fetched via curl|bash or run from a checked-out repo.

REPO_URL="https://github.com/DrDBanner/inmanage.git"
INSTALLER_BRANCH="${INSTALLER_BRANCH:-development}"
BRANCH="${BRANCH:-$INSTALLER_BRANCH}"

MODE="${MODE:-}"
TARGET_DIR="${TARGET_DIR:-}"
SYMLINK_DIR="${SYMLINK_DIR:-}"
INSTALL_OWNER="${INSTALL_OWNER:-}"
INSTALL_PERMS="${INSTALL_PERMS:-}"
SOURCE_DIR="${SOURCE_DIR:-}"
RUN_USER="${RUN_USER:-${RUN_AS_USER:-}}"
DEBUG_FLAG="${DEBUG_FLAG:-false}"
TMP_DIR=""

log() {
  local level="$1"; shift
  printf "[%s] %s\n" "$level" "$*" >&2
}

usage() {
  cat <<EOF
inmanage installer

Usage: bash install_inmanage.sh [--mode system|user|project] [--target DIR] [--symlink-dir DIR] [--install-owner USER:GROUP] [--install-perms DIR:FILE] [--run-user USER] [--branch BRANCH] [--source PATH]

Modes:
  system          install to /usr/local/share/inmanage, symlinks to /usr/local/bin (requires sudo)
  user            install to ~/.local/share/inmanage, symlinks to ~/.local/bin
  project         install to ./.inmanage/cli, symlinks locally

Notes:
  - Auto mode: system when run as root, otherwise user.
  - Use --run-user for user installs (e.g., www-data).

Options:
  --source PATH   Use an existing checkout at PATH instead of git cloning.
  --install-owner USER:GROUP  Set ownership on the install directory (system installs).
  --install-perms DIR:FILE    Set permissions on the install directory (e.g. 775:664).
  --debug         Enable verbose installer output.

Examples:
  curl -fsSL ${REPO_URL%.*}/raw/${BRANCH}/install_inmanage.sh | bash
  curl -fsSL ${REPO_URL%.*}/raw/${BRANCH}/install_inmanage.sh | sudo bash -s -- --mode system
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode=*) MODE="${1#*=}"; shift ;;
      --mode) MODE="$2"; shift 2 ;;
      --target=*) TARGET_DIR="${1#*=}"; shift ;;
      --target) TARGET_DIR="$2"; shift 2 ;;
      --symlink-dir=*) SYMLINK_DIR="${1#*=}"; shift ;;
      --symlink-dir) SYMLINK_DIR="$2"; shift 2 ;;
      --install-owner=*) INSTALL_OWNER="${1#*=}"; shift ;;
      --install-owner) INSTALL_OWNER="$2"; shift 2 ;;
      --install-perms=*) INSTALL_PERMS="${1#*=}"; shift ;;
      --install-perms) INSTALL_PERMS="$2"; shift 2 ;;
      --run-user=*) RUN_USER="${1#*=}"; shift ;;
      --run-user) RUN_USER="$2"; shift 2 ;;
      --branch=*) BRANCH="${1#*=}"; shift ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --source=*) SOURCE_DIR="${1#*=}"; shift ;;
      --source) SOURCE_DIR="$2"; shift 2 ;;
      --debug) DEBUG_FLAG=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log ERR "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log ERR "Missing required command: $1"; exit 1; }
}

maybe_default_run_user() {
  if [[ -z "$RUN_USER" && -n "${SUDO_USER:-}" ]]; then
    RUN_USER="$SUDO_USER"
  fi
}

auto_source_dir() {
  if [[ -n "$SOURCE_DIR" ]]; then
    return 0
  fi
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/inmanage.sh" ]]; then
      SOURCE_DIR="$script_dir"
    fi
  fi
}

prepare_source() {
  if [[ -n "$SOURCE_DIR" ]]; then
    if [[ ! -d "$SOURCE_DIR" || ! -f "$SOURCE_DIR/inmanage.sh" ]]; then
      log ERR "SOURCE_DIR must contain an inmanage checkout (missing inmanage.sh): $SOURCE_DIR"
      exit 1
    fi
    return 0
  fi

  require_cmd git
  TMP_DIR="$(mktemp -d)"
  log INFO "Cloning $REPO_URL (branch: $BRANCH) into $TMP_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$TMP_DIR"
  SOURCE_DIR="$TMP_DIR"
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

run_self_install() {
  local script="$SOURCE_DIR/inmanage.sh"
  local args=("self" "install")

  [[ -n "$MODE" ]] && args+=("--install-mode=$MODE")
  [[ -n "$TARGET_DIR" ]] && args+=("--target-dir=$TARGET_DIR")
  [[ -n "$SYMLINK_DIR" ]] && args+=("--symlink-dir=$SYMLINK_DIR")
  [[ -n "$INSTALL_OWNER" ]] && args+=("--install-owner=$INSTALL_OWNER")
  [[ -n "$INSTALL_PERMS" ]] && args+=("--install-perms=$INSTALL_PERMS")
  [[ -n "$RUN_USER" ]] && args+=("--run-user=$RUN_USER")
  [[ "$DEBUG_FLAG" == true ]] && args+=("--debug")

  log INFO "Bootstrap source: $SOURCE_DIR"
  log INFO "Branch: $BRANCH"

  bash "$script" "${args[@]}"
}

main() {
  parse_args "$@"
  auto_source_dir
  maybe_default_run_user
  prepare_source
  trap cleanup EXIT
  run_self_install
}

main "$@"
