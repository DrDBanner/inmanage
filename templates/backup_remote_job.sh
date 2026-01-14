#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ULTIMATE RSYNC BACKUP SCRIPT
# Runs on the backup host and pulls from the app host via SSH (scp/rsync).
# by Dr.D.Banner - https://github.com/DrDBanner
###############################################################################
#
# DESCRIPTION:
#   Runs on the backup host and pulls files/folders from the app host via SSH.
#   Uses `scp` for individual files and `rsync` for directories.
#   Optional remote pre/post hooks can run on the app host (e.g. DB dump).
#
# BACKUP BEHAVIOR:
#   - Incremental by default (rsync delta transfers → faster, less bandwidth).
#   - Controlled by `RSYNC_OPTS`.
#     Example: RSYNC_OPTS="-avz --delete --bwlimit=5000"
#       -a archive, -v verbose, -z compress
#       --delete sync deletions, --bwlimit KB/s
#
# PATH COLLISIONS:
#   - Files are written under $LOCAL_BASE/.
#   - If filenames collide, the file goes into a folder named after its parent.
#     Example: /etc/nginx/nginx.conf → $LOCAL_BASE/nginx/nginx.conf
#
# USAGE:
#   1. Fill the CONFIGURATION section (REMOTE_USER/REMOTE_HOST/LOCAL_BASE/SSH_KEY).
#   2. Uncomment paths in REMOTE_FILES and REMOTE_PATHS.
#   3. Make it executable: chmod +x backup_remote_projectname.sh
#   4. Run manually: ./backup_remote_projectname.sh
#   5. Cron example: 30 3 * * * /path/to/backup_remote_projectname.sh >> /var/log/remote_backup.log 2>&1
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
# SSH KEY SETUP (passwordless login required):
#   - Run these commands on the machine where this script runs (your LOCAL machine; the destination).
#   - The SSH connection goes FROM your LOCAL machine TO the REMOTE server.
#   - The REMOTE server is the machine you want to pull files/folders from for your LOCAL off-site backups.
#   1) Quick test (should NOT ask for a password):
#        ssh user@host
#   2) If it asks for a password, generate a key and copy its public key:
#        ssh-keygen -t ed25519 -f ~/.ssh/inmanage_backup
#        ssh-copy-id -i ~/.ssh/inmanage_backup.pub user@host
#      Note: the key name/path is up to you (depends on how you run ssh-keygen).
#   3) Test again:
#        ssh user@host
#   4) If you use a non-default key, set SSH_KEY to its path.
#
# TODO: Add "inm backup spawn remote-backup-script" flow that generates this
# script + an .env template, supports REMOTE_PRE_HOOK, rsync/scp selection,
# optional verify, and retention settings.
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
#  "/path/to/project/.backups/" 
)

# Optional remote scripts to execute before/after backup
# Example pre-hook using inmanage on the remote to dump DB (only) into the backup dir:
#   (Requires inmanage installed on the remote server.)
#   Set directly:
#     REMOTE_PRE_HOOK="inmanage core backup --db=true --storage=false --uploads=false --bundle=false --name=remote_db_only"
#   And add the backup directory (e.g. /path/to/.backup/) to REMOTE_PATHS so the new DB dump is pulled:
#     REMOTE_PATHS=( "/path/to/.backup/" )
#   Use SSH key auth; ensure the command runs as the correct user (web user) if needed.
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
RSYNC_LOG_FULL=false           # true = include full rsync output in logs

# ----------------------------------------------------
# END CONFIGURATION BLOCK
# ----------------------------------------------------
######################################################
# ----------------------------------------------------
# DO NOT TOUCH BELOW UNLESS YOU KNOW WHAT YOU’RE DOING
# ----------------------------------------------------
# ----------------------------------------------------
# ----------------------------------------------------
# ----------------------------------------------------
# ----------------------------------------------------
# ----------------------------------------------------
# ----------------------------------------------------
# ----------------------------------------------------
# DO NOT TOUCH BELOW UNLESS YOU KNOW WHAT YOU’RE DOING
# ----------------------------------------------------


# Build SSH options (port + key if specified)
# Build SSH options array (port + key if specified)
SSH_OPTS=(-p "${SSH_PORT}")

# If SSH_KEY is set, add it to the SSH options
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=(-i "${SSH_KEY}")

# Parse RSYNC_OPTS into an array for safe argument passing
RSYNC_OPTS_ARR=()
if [[ -n "${RSYNC_OPTS:-}" ]]; then
  # shellcheck disable=SC2206
  RSYNC_OPTS_ARR=(${RSYNC_OPTS})
fi

# -----------------------
# Script Starts Here
# -----------------------

# Timing
START_TS="$(date +%s)"
START_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"

# Format duration (seconds) as HH:MM:SS
format_duration() {
  local total="$1"
  local hours=$((total / 3600))
  local mins=$(((total % 3600) / 60))
  local secs=$((total % 60))
  printf '%02d:%02d:%02d' "$hours" "$mins" "$secs"
}

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
    ssh "${SSH_OPTS[@]}" "$hook_user@$hook_host" -- bash -lc 'exec "$1"' _ "$hook_path"
    echo "-> Hook $hook_path finished successfully."
  else
    echo "-> No hook defined, skipping."
  fi
}

# Checks if remote file/directory exists
remote_exists() {
  local path="$1"
  ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" -- bash -lc 'test -e "$1"' _ "$path"
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
      scp "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_FILE}" "${LOCAL_DST}"
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
      if [[ "$RSYNC_LOG_FULL" == true ]]; then
        echo "-> RSYNC: ${REMOTE_PATH} → ${LOCAL_PATH}"
        rsync "${RSYNC_OPTS_ARR[@]}" \
          -e "ssh ${SSH_OPTS[*]}" \
          "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" \
          "${LOCAL_PATH}"
      else
        echo "-> RSYNC: ${REMOTE_PATH} → ${LOCAL_PATH} (output suppressed)"
        rsync "${RSYNC_OPTS_ARR[@]}" \
          -e "ssh ${SSH_OPTS[*]}" \
          "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" \
          "${LOCAL_PATH}" >/dev/null
      fi
    else
      echo "WARNING: Remote path '${REMOTE_PATH}' not found. Skipping."
    fi
  done
else
  echo "-> No directories defined for RSYNC. Skipping."
fi

# Run Post-Hook (optional) ---
run_remote_hook "$REMOTE_POST_HOOK" "$REMOTE_POST_HOOK_USER" "$REMOTE_POST_HOOK_HOST"

END_TS="$(date +%s)"
END_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"
ELAPSED="$((END_TS - START_TS))"
ELAPSED_FMT="$(format_duration "$ELAPSED")"

echo "Backup completed successfully."
echo "Started: ${START_HUMAN}"
echo "Finished: ${END_HUMAN}"
echo "Duration: ${ELAPSED_FMT}"
