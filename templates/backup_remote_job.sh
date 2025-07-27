#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ULTIMATE RSYNC BACKUP SCRIPT
# by Dr.D.Banner - https://github.com/DrDBanner
###############################################################################
#
# DESCRIPTION:
#   This script performs secure backups of files and directories from a remote
#   server via SSH. It uses `scp` for single files and `rsync` for
#   full directory syncs. Optional *pre* and *post* hook scripts can be executed
#   remotely before and after the backup (e.g. to trigger a DB dump).
#
# BACKUP TYPE:
#   - This script performs **incremental backups** by default.
#     That means only changed files are copied, which saves bandwidth and time.
#   - This behavior is controlled by the `RSYNC_OPTS` variable.
#
#     For example:
#
#       RSYNC_OPTS="-avz --delete --bwlimit=5000"
#     - `-a`  → archive mode (recursive, keeps timestamps, symlinks, etc.)
#     - `-v`  → verbose
#     - `-z`  → compress data during transfer
#     - `--delete`  → remove copied local files if they were deleted on the remote server as well
#     - `--delete`  → is optional, but useful for keeping the local backup in sync
#     - `--bwlimit` → limit transfer speed (e.g. 5000 = 5 MB/s)
#
#   - To change this behavior (e.g. full copy every time, no deletes),
#     adjust `RSYNC_OPTS` accordingly.
#
#   - Files will be downloaded into $LOCAL_BASE/
#     If a filename conflict occurs, the file is redirected into a subfolder named after its parent directory.
#
#     Example:
#
#     /etc/nginx/nginx.conf and /etc/apache2/nginx.conf
#     >   → $LOCAL_BASE/nginx/nginx.conf
#     >   → $LOCAL_BASE/apache2/nginx.conf
#
#
# USAGE:
#   1. Fill in the CONFIGURATION section below:
#      - Set REMOTE_USER, REMOTE_HOST, and optionally SSH_KEY
#      - Uncomment file and directory paths in REMOTE_FILES and REMOTE_PATHS
#      - Set LOCAL_BASE to your desired backup destination
#
#   2. Make the script executable:
#        chmod +x backup_remote_projectname.sh
#
#   3. Run manually:
#        ./backup_remote_projectname.sh
#
#   4. Or add to crontab for automated execution (e.g. every night at 03:30):
#        30 3 * * * /path/to/backup_remote_projectname.sh >> /var/log/remote_backup.log 2>&1
#
# PLATFORM SUPPORT:
#   - macOS (tested with Homebrew Bash and system bash)
#   -  Linux (Ubuntu/Debian/CentOS/etc.)
#   -  Windows 10/11 via WSL (Windows Subsystem for Linux)
#
# REQUIREMENTS:
#   - Bash 4+
#   - ssh, scp, rsync installed
#   - Remote server must be accessible via SSH
#   - SSH key-based login is REQUIRED (no password prompts)
#
# SSH KEY SETUP:
#   - If you can already connect with `ssh user@host` without password,
#     no need to set SSH_KEY.
#   - Otherwise, generate a key and add it to the remote server:
#       ssh-keygen -t ed25519
#       ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host
#
###############################################################################


# ----------------------------------------------------
# USER CONFIGURATION
# ----------------------------------------------------

REMOTE_USER=""                 # SSH login name, e.g. "admin"
REMOTE_HOST=""                 # Remote server, e.g. "example.com"
SSH_PORT=22                    # SSH port (default: 22)
SSH_KEY=""                     # Optional: path to private key (e.g. ~/.ssh/id_ed25519)

# LOCAL_BASE: All remote files and directories will be saved under this local path.
# This should point to an existing or creatable directory on your local machine.
# Example: "$HOME/Remote-Backups/Job_Name"
# If the directory does not exist, it will be created automatically.

LOCAL_BASE="$HOME/Remote-Backups/Job_Name"


# Single files to back up (infinite locations) using SCP
# → To activate a file path, remove the leading "#" below.
REMOTE_FILES=(
#  "/absolute/path/to/file1.txt"
#  "/var/log/mylog.log"
)

# Directories (infinite locations) to back up using RSYNC
# → To activate a directory, remove the leading "#" below.
REMOTE_PATHS=(
#  "/etc/nginx/"
#  "/var/www/html/"
#  "/path/to/your/backup/location/your/want/to/copy/to/your/local/machine"
)

# Optional remote scripts to execute before/after backup
# e.g. REMOTE_PRE_HOOK="/usr/local/bin/dump_mysql.sh"
REMOTE_PRE_HOOK=""             # Path to script/command to run before backup
REMOTE_PRE_HOOK_USER=""        # Optional override of user
REMOTE_PRE_HOOK_HOST=""        # Optional override of host

REMOTE_POST_HOOK=""            # Path to script/command to run after backup
REMOTE_POST_HOOK_USER=""       # Optional override of user
REMOTE_POST_HOOK_HOST=""       # Optional override of host

# If true, backup directory mirrors full remote path (e.g. /var/www/html → $LOCAL_BASE/var/www/html)
PRESERVE_FULL_PATH=false

# RSYNC options
# --bwlimit limits bandwidth in KB/s (e.g. 5000 = 5 MB/s) to avoid saturating your connection
RSYNC_OPTS="-avz --delete --bwlimit=5000"

# ----------------------------------------------------
# END CONFIGURATION BLOCK
# ----------------------------------------------------
######################################################
# ----------------------------------------------------
# DO NOT TOUCH BELOW UNLESS YOU KNOW WHAT YOU’RE DOING
# ----------------------------------------------------

# Build SSH options (port + key if specified)
SSH_OPTS="-p ${SSH_PORT}"

# If SSH_KEY is set, add it to the SSH options
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=" -i ${SSH_KEY}"

# -----------------------
# Script Starts Here
# -----------------------

# Executes an optional remote hook script via SSH
# Parameters:
#   $1 - Path to remote script to execute (e.g. "/usr/local/bin/prepare_backup.sh")
#   $2 - Optional SSH username (falls leer → REMOTE_USER)
#   $3 - Optional SSH host (falls leer → REMOTE_HOST)
run_remote_hook() {
  local hook_path="$1"
  local hook_user="$2"
  local hook_host="$3"

  if [[ -n "$hook_path" ]]; then
    [[ -z "$hook_user" ]] && hook_user="$REMOTE_USER"
    [[ -z "$hook_host" ]] && hook_host="$REMOTE_HOST"
    echo "-> Running remote hook: $hook_path on $hook_user@$hook_host ..."
    ssh $SSH_OPTS "$hook_user@$hook_host" "$hook_path"
    echo "-> Hook $hook_path finished successfully."
  else
    echo "-> No hook defined, skipping."
  fi
}

# Checks if remote file/directory exists
remote_exists() {
  local path="$1"
  ssh "${SSH_OPTS}" "${REMOTE_USER}@${REMOTE_HOST}" "test -e '$path'"
}

# Run Pre-Hook (optional) ---
run_remote_hook "$REMOTE_PRE_HOOK" "$REMOTE_PRE_HOOK_USER" "$REMOTE_PRE_HOOK_HOST"

# Step 2: Backup individual files via SCP
# If a file with the same name already exists, store it under a folder named after its parent directory.
if (( ${#REMOTE_FILES[@]} > 0 )); then
  for REMOTE_FILE in "${REMOTE_FILES[@]}"; do
    if remote_exists "${REMOTE_FILE}"; then
      FILENAME=$(basename "${REMOTE_FILE}")
      LOCAL_DST="${LOCAL_BASE}/${FILENAME}"

      # Check for conflict: If file already exists, use parent-dir fallback
      if [[ -e "${LOCAL_DST}" ]]; then
        PARENT_DIR=$(basename "$(dirname "${REMOTE_FILE}")")
        LOCAL_DST="${LOCAL_BASE}/${PARENT_DIR}/${FILENAME}"
        echo "Conflict: '${FILENAME}' already exists. Using subfolder '${PARENT_DIR}/'."
      fi

      mkdir -p "$(dirname "${LOCAL_DST}")"
      echo "-> SCP: ${REMOTE_FILE} → ${LOCAL_DST}"
      scp ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_FILE}" "${LOCAL_DST}"
    else
      echo "WARNING: Remote file '${REMOTE_FILE}' not found. Skipping."
    fi
  done
else
  echo "-> No files defined for SCP. Skipping."
fi


# Step 3: Backup directories via RSYNC
if (( ${#REMOTE_PATHS[@]} > 0 )); then
  for REMOTE_PATH in "${REMOTE_PATHS[@]}"; do
    if remote_exists "${REMOTE_PATH}"; then
      if [[ "${PRESERVE_FULL_PATH}" == true ]]; then
        REL_PATH="${REMOTE_PATH#/}"
        REL_PATH="${REL_PATH%/}"
        LOCAL_PATH="${LOCAL_BASE}/${REL_PATH}"
      else
        LOCAL_PATH="${LOCAL_BASE}"
      fi
      mkdir -p "${LOCAL_PATH}"
      echo "-> RSYNC: ${REMOTE_PATH} → ${LOCAL_PATH}"
      rsync ${RSYNC_OPTS} \
        -e "ssh ${SSH_OPTS}" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" \
        "${LOCAL_PATH}"
    else
      echo "WARNING: Remote path '${REMOTE_PATH}' not found. Skipping."
    fi
  done
else
  echo "-> No directories defined for RSYNC. Skipping."
fi

# Run Post-Hook (optional) ---
run_remote_hook "$REMOTE_POST_HOOK" "$REMOTE_POST_HOOK_USER" "$REMOTE_POST_HOOK_HOST"

echo "Backup completed successfully."
